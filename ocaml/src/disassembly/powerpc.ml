(*
    This file is part of BinCAT.
    Copyright 2014-2018 - Airbus Group

    BinCAT is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published by
    the Free Software Foundation, either version 3 of the License, or (at your
    option) any later version.

    BinCAT is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with BinCAT.  If not, see <http://www.gnu.org/licenses/>.
*)

(*
   Decoder for PowerPC
*)
module L = Log.Make(struct let name = "powerpc" end)

module Make(Domain: Domain.T)(Stubs: Stubs.T with type domain_t := Domain.t) =
struct

  type ctx_t = unit

  open Data
  open Asm
  open Decodeutils

  module Cfa = Cfa.Make(Domain)

  type state = {
    mutable g             : Cfa.t;        (** current cfa *)
    mutable b             : Cfa.State.t;  (** state predecessor *)
    a                     : Address.t;    (** current address to decode *)
    buf                   : string;       (** buffer to decode *)
    endianness            : Config.endianness_t;      (** whether memory access is little endian *)
  }


  (************************************************************************)
  (* Creation of the general purpose registers *)
  (************************************************************************)
  let (register_tbl: (int, Register.t) Hashtbl.t) = Hashtbl.create 16;;
  let r0 = Register.make ~name:"r0" ~size:32;;
  let r1 = Register.make ~name:"r1" ~size:32;;
  let r2 = Register.make ~name:"r2" ~size:32;;
  let r3 = Register.make ~name:"r3" ~size:32;;
  let r4 = Register.make ~name:"r4" ~size:32;;
  let r5 = Register.make ~name:"r5" ~size:32;;
  let r6 = Register.make ~name:"r6" ~size:32;;
  let r7 = Register.make ~name:"r7" ~size:32;;
  let r8 = Register.make ~name:"r8" ~size:32;;
  let r9 = Register.make ~name:"r9" ~size:32;;
  let r10 = Register.make ~name:"r10" ~size:32;;
  let r11 = Register.make ~name:"r11" ~size:32;;
  let r12 = Register.make ~name:"r12" ~size:32;;
  let r13 = Register.make ~name:"r13" ~size:32;;
  let r14 = Register.make ~name:"r14" ~size:32;;
  let r15 = Register.make ~name:"r15" ~size:32;;
  let r16 = Register.make ~name:"r16" ~size:32;;
  let r17 = Register.make ~name:"r17" ~size:32;;
  let r18 = Register.make ~name:"r18" ~size:32;;
  let r19 = Register.make ~name:"r19" ~size:32;;
  let r20 = Register.make ~name:"r20" ~size:32;;
  let r21 = Register.make ~name:"r21" ~size:32;;
  let r22 = Register.make ~name:"r22" ~size:32;;
  let r23 = Register.make ~name:"r23" ~size:32;;
  let r24 = Register.make ~name:"r24" ~size:32;;
  let r25 = Register.make ~name:"r25" ~size:32;;
  let r26 = Register.make ~name:"r26" ~size:32;;
  let r27 = Register.make ~name:"r27" ~size:32;;
  let r28 = Register.make ~name:"r28" ~size:32;;
  let r29 = Register.make ~name:"r29" ~size:32;;
  let r30 = Register.make ~name:"r30" ~size:32;;
  let r31 = Register.make ~name:"r31" ~size:32;;

  let lr = Register.make ~name:"lr" ~size:32;;

  (* condition flags are modeled as registers of size 1 *)
  let lt0 = Register.make ~name:"lt0" ~size:1;;
  let gt0 = Register.make ~name:"gt0" ~size:1;;
  let eq0 = Register.make ~name:"eq0" ~size:1;;
  let so0 = Register.make ~name:"so0" ~size:1;;

  module Imports = PowerpcImports.Make(Domain)(Stubs)

  let reg n =
    match n with
    | 0 -> r0
    | 1 -> r1
    | 2 -> r2
    | 3 -> r3
    | 4 -> r4
    | 5 -> r5
    | 6 -> r6
    | 7 -> r7
    | 8 -> r8
    | 9 -> r9
    | 10 -> r10
    | 11 -> r11
    | 12 -> r12
    | 13 -> r13
    | 14 -> r14
    | 15 -> r15
    | 16 -> r16
    | 17 -> r17
    | 18 -> r18
    | 19 -> r19
    | 20 -> r20
    | 21 -> r21
    | 22 -> r22
    | 23 -> r23
    | 24 -> r24
    | 25 -> r25
    | 26 -> r26
    | 27 -> r27
    | 28 -> r28
    | 29 -> r29
    | _ -> L.abort (fun p -> p "Unknown register number %i" n)

  let treg n =
    T (reg n)

  let preg n a b =
    P ((reg n), a, b)

  let lt_is_set = Cmp(EQ, Lval (V (T lt0)), const 1 1)
  let gt_is_set = Cmp(EQ, Lval (V (T gt0)), const 1 1)
  let eq_is_set = Cmp(EQ, Lval (V (T eq0)), const 1 1)
  let so_is_set = Cmp(EQ, Lval (V (T so0)), const 1 1)
  let lt_is_clear = Cmp(EQ, Lval (V (T lt0)), const 0 1)
  let gt_is_clear = Cmp(EQ, Lval (V (T gt0)), const 0 1)
  let eq_is_clear = Cmp(EQ, Lval (V (T eq0)), const 0 1)
  let so_is_clear = Cmp(EQ, Lval (V (T so0)), const 0 1)

  (* fatal error reporting *)
  let error a msg =
    L.abort (fun p -> p "at %s: %s" (Address.to_string a) msg)

  let return (s: state) (instruction: int) (stmts: Asm.stmt list): Cfa.State.t * Data.Address.t =
    s.b.Cfa.State.stmts <- stmts;
    s.b.Cfa.State.bytes <-
        [ Char.chr (instruction land 0xff) ;
          Char.chr ((instruction lsr 8) land 0xff) ;
          Char.chr ((instruction lsr 16) land 0xff) ;
          Char.chr ((instruction lsr 24) land 0xff) ];
    s.b, Data.Address.add_offset s.a (Z.of_int 4)

  let build_instruction s str =
    match s.endianness with
    | Config.LITTLE ->
        (Char.code (String.get str 0))
        lor ((Char.code (String.get str 1)) lsl 8)
        lor ((Char.code (String.get str 2)) lsl 16)
        lor ((Char.code (String.get str 3)) lsl 24)
    | Config.BIG ->
        (Char.code (String.get str 3))
        lor ((Char.code (String.get str 2)) lsl 8)
        lor ((Char.code (String.get str 1)) lsl 16)
        lor ((Char.code (String.get str 0)) lsl 24)

  let decode s: Cfa.State.t * Data.Address.t =
    let str = String.sub s.buf 0 4 in
    let instruction = build_instruction s str in
    let stmts = match instruction with
      | _ -> error s.a (Printf.sprintf "Unknown opcode 0x%x" instruction) in
    return s instruction stmts


  let parse text cfg _ctx state addr _oracle =

    let s =  {
      g = cfg;
      b = state;
      a = addr;
      buf = text;
      endianness = !Config.endianness;
    }
    in
    try
      let v', ip' = decode s in
      Some (v', ip', ())
    with
      | Exceptions.Error _ as e -> raise e
      | _  -> (*end of buffer *) None


  let init () =
    Imports.init ()

  let overflow_expression () = Lval (V (T so0))

end