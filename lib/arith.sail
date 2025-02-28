$ifndef _ARITH
$define _ARITH

$include <flow.sail>

// ***** Addition *****

val add_atom = {ocaml: "add_int", interpreter: "add_int", lem: "integerAdd", c: "add_int", coq: "Z.add"} : forall 'n 'm.
  (int('n), int('m)) -> int('n + 'm)

val add_int = {ocaml: "add_int", interpreter: "add_int", lem: "integerAdd", c: "add_int", coq: "Z.add"} : (int, int) -> int

overload operator + = {add_atom, add_int}

// ***** Subtraction *****

val sub_atom = {ocaml: "sub_int", interpreter: "sub_int", lem: "integerMinus", c: "sub_int", coq: "Z.sub"} : forall 'n 'm.
  (int('n), int('m)) -> int('n - 'm)

val sub_int = {ocaml: "sub_int", interpreter: "sub_int", lem: "integerMinus", c: "sub_int", coq: "Z.sub"} : (int, int) -> int

overload operator - = {sub_atom, sub_int}

val sub_nat = {
  ocaml: "(fun (x,y) -> let n = sub_int (x,y) in if Big_int.less_equal n Big_int.zero then Big_int.zero else n)",
  lem: "integerMinus",
  _: "sub_nat"
} : (nat, nat) -> nat

// ***** Negation *****

val negate_atom = {ocaml: "negate", interpreter: "negate", lem: "integerNegate", c: "neg_int", coq: "Z.opp"} : forall 'n. int('n) -> int(- 'n)

val negate_int = {ocaml: "negate", interpreter: "negate", lem: "integerNegate", c: "neg_int", coq: "Z.opp"} : int -> int

overload negate = {negate_atom, negate_int}

// ***** Multiplication *****

val mult_atom = {ocaml: "mult", interpreter: "mult", lem: "integerMult", c: "mult_int", coq: "Z.mul"} : forall 'n 'm.
  (int('n), int('m)) -> int('n * 'm)

val mult_int = {ocaml: "mult", interpreter: "mult", lem: "integerMult", c: "mult_int", coq: "Z.mul"} : (int, int) -> int

overload operator * = {mult_atom, mult_int}

val "print_int" : (string, int) -> unit

val "prerr_int" : (string, int) -> unit

// ***** Integer shifts *****

/*!
A common idiom in asl is to take two bits of an opcode and convert in into a variable like
```
let elsize = shl_int(8, UInt(size))
```
THIS ensures that in this case the typechecker knows that the end result will be a value in the set `{8, 16, 32, 64}`
*/
val _shl8 = {c: "shl_mach_int", coq: "shl_int_8", _: "shl_int"} :
  forall 'n, 0 <= 'n <= 3. (int(8), int('n)) -> {'m, 'm in {8, 16, 32, 64}. int('m)}

/*!
Similarly, we can shift 32 by either 0 or 1 to get a value in `{32, 64}`
*/
val _shl32 = {c: "shl_mach_int", coq: "shl_int_32", _: "shl_int"} :
  forall 'n, 'n in {0, 1}. (int(32), int('n)) -> {'m, 'm in {32, 64}. int('m)}

val _shl_int = "shl_int" : (int, int) -> int

overload shl_int = {_shl8, _shl32, _shl_int}

val _shr32 = {c: "shr_mach_int", coq: "shr_int_32", _: "shr_int"} : forall 'n, 0 <= 'n <= 31. (int('n), int(1)) -> {'m, 0 <= 'm <= 15. int('m)}

val _shr_int = "shr_int" : (int, int) -> int

overload shr_int = {_shr32, _shr_int}

// ***** div and mod *****

/*! Truncating division (rounds towards zero) */
val tdiv_int = {
  ocaml: "tdiv_int",
  interpreter: "tdiv_int",
  lem: "tdiv_int",
  c: "tdiv_int",
  coq: "Z.quot"
} : (int, int) -> int

/*! Remainder for truncating division (has sign of dividend) */
val tmod_int = {
  ocaml: "tmod_int",
  interpreter: "tmod_int",
  lem: "tmod_int",
  c: "tmod_int",
  coq: "Z.rem"
} : (int, int) -> nat

val abs_int = {
  smt : "abs",
  ocaml: "abs_int",
  interpreter: "abs_int",
  lem: "integerAbs",
  c: "abs_int",
  coq: "Z.abs"
} : int -> int

$endif
