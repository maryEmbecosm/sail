$ifndef _VECTOR_DEC
$define _VECTOR_DEC

$include <flow.sail>

type bits ('n : Int) = vector('n, dec, bit)

val eq_bits = {
  ocaml: "eq_list",
  interpreter: "eq_list",
  lem: "eq_vec",
  c: "eq_bits",
  coq: "eq_vec"
} : forall 'n. (vector('n, dec, bit), vector('n, dec, bit)) -> bool

overload operator == = {eq_bit, eq_bits}

val neq_bits = {
  lem: "neq_vec",
  c: "neq_bits",
  coq: "neq_vec"
} : forall 'n. (vector('n, dec, bit), vector('n, dec, bit)) -> bool

function neq_bits(x, y) = not_bool(eq_bits(x, y))

overload operator != = {neq_bits}

val bitvector_length = {coq: "length_mword", _:"length"} : forall 'n. bits('n) -> atom('n)

val vector_length = {
  ocaml: "length",
  interpreter: "length",
  lem: "length_list",
  c: "length",
  coq: "vec_length"
} : forall 'n ('a : Type). vector('n, dec, 'a) -> atom('n)

overload length = {bitvector_length, vector_length}

val count_leading_zeros = "count_leading_zeros" : forall 'N , 'N >= 1. bits('N) -> {'n, 0 <= 'n <= 'N . atom('n)}
/*
function count_leading_zeros x = {
  foreach (i from ('N - 1) to 0 by 1 in dec)
    if [x[i]] == 0b1 then return 'N - i - 1;
  return 'N;
}
*/

val "print_bits" : forall 'n. (string, bits('n)) -> unit

val "prerr_bits" : forall 'n. (string, bits('n)) -> unit

val sail_sign_extend = "sign_extend" : forall 'n 'm, 'm >= 'n. (bits('n), atom('m)) -> bits('m)

val sail_zero_extend = "zero_extend" : forall 'n 'm, 'm >= 'n. (bits('n), atom('m)) -> bits('m)

/*!
THIS`(v, n)` truncates `v`, keeping only the _least_ significant `n` bits.
 */
val truncate = {
  ocaml: "vector_truncate",
  interpreter: "vector_truncate",
  lem: "vector_truncate",
  coq: "vector_truncate",
  c: "sail_truncate"
} : forall 'm 'n, 'm >= 0 & 'm <= 'n. (vector('n, dec, bit), atom('m)) -> vector('m, dec, bit)

/*!
THIS`(v, n)` truncates `v`, keeping only the _most_ significant `n` bits.
 */
val truncateLSB = {
  ocaml: "vector_truncateLSB",
  interpreter: "vector_truncateLSB",
  lem: "vector_truncateLSB",
  coq: "vector_truncateLSB",
  c: "sail_truncateLSB"
} : forall 'm 'n, 'm >= 0 & 'm <= 'n. (vector('n, dec, bit), atom('m)) -> vector('m, dec, bit)

val sail_mask : forall 'len 'v, 'len >= 0 & 'v >= 0. (atom('len), vector('v, dec, bit)) -> vector('len, dec, bit)

function sail_mask(len, v) = if len <= length(v) then truncate(v, len) else sail_zero_extend(v, len)

overload operator ^ = {sail_mask}

val bitvector_concat = {ocaml: "append", interpreter: "append", lem: "concat_vec", c: "append", coq: "concat_vec"} : forall ('n : Int) ('m : Int).
  (bits('n), bits('m)) -> bits('n + 'm)

overload append = {bitvector_concat}

/* Used for creating long bitvector literals in the C backend. */
val "append_64" : forall 'n. (bits('n), bits(64)) -> bits('n + 64)

val bitvector_access = {
  ocaml: "access",
  interpreter: "access",
  lem: "access_vec_dec",
  coq: "access_vec_dec",
  c: "vector_access"
} : forall ('n : Int) ('m : Int), 0 <= 'm < 'n . (bits('n), int('m)) -> bit

val plain_vector_access = {
  ocaml: "access",
  interpreter: "access",
  lem: "access_list_dec",
  coq: "vec_access_dec",
  c: "vector_access"
} : forall ('n : Int) ('m : Int) ('a : Type), 0 <= 'm < 'n. (vector('n, dec, 'a), atom('m)) -> 'a

overload vector_access = {bitvector_access, plain_vector_access}

val bitvector_update = {
  ocaml: "update",
  interpreter: "update",
  lem: "update_vec_dec",
  coq: "update_vec_dec",
  c: "vector_update"
} : forall 'n 'm, 0 <= 'm < 'n. (bits('n), atom('m), bit) -> bits('n)

val plain_vector_update = {
  ocaml: "update",
  interpreter: "update",
  lem: "update_list_dec",
  coq: "vec_update_dec",
  c: "vector_update"
} : forall 'n 'm ('a : Type), 0 <= 'm < 'n. (vector('n, dec, 'a), atom('m), 'a) -> vector('n, dec, 'a)

overload vector_update = {bitvector_update, plain_vector_update}

val add_bits = {
  ocaml: "add_vec",
  interpreter: "add_vec",
  lem: "add_vec",
  c: "add_bits",
  coq: "add_vec"
} : forall 'n. (bits('n), bits('n)) -> bits('n)

val add_bits_int = {
  ocaml: "add_vec_int",
  interpreter: "add_vec_int",
  lem: "add_vec_int",
  c: "add_bits_int",
  coq: "add_vec_int"
} : forall 'n. (bits('n), int) -> bits('n)

overload operator + = {add_bits, add_bits_int}

val sub_bits = {
  ocaml: "sub_vec",
  lem: "sub_vec",
  c: "sub_bits",
  coq: "sub_vec"
} : forall 'n. (bits('n), bits('n)) -> bits('n)

val not_vec = {c: "not_bits", _: "not_vec"} : forall 'n. bits('n) -> bits('n)

val and_vec = {
  lem: "and_vec",
  c: "and_bits",
  coq: "and_vec",
  ocaml: "and_vec",
  interpreter: "and_vec"
} : forall 'n. (bits('n), bits('n)) -> bits('n)

overload operator & = {and_vec}

val or_vec = {
  lem: "or_vec",
  c: "or_bits",
  coq: "or_vec",
  ocaml: "or_vec",
  interpreter: "or_vec"
} : forall 'n. (bits('n), bits('n)) -> bits('n)

overload operator | = {or_vec}

val vector_subrange = {
  ocaml: "subrange",
  interpreter: "subrange",
  lem: "subrange_vec_dec",
  c: "vector_subrange",
  coq: "subrange_vec_dec"
} : forall ('n : Int) ('m : Int) ('o : Int), 0 <= 'o <= 'm < 'n.
  (bits('n), atom('m), atom('o)) -> bits('m - 'o + 1)

val vector_update_subrange = {
  ocaml: "update_subrange",
  interpreter: "update_subrange",
  lem: "update_subrange_vec_dec",
  c: "vector_update_subrange",
  coq: "update_subrange_vec_dec"
} : forall 'n 'm 'o, 0 <= 'o <= 'm < 'n. (bits('n), atom('m), atom('o), bits('m - ('o - 1))) -> bits('n)

val sail_shiftleft = "shiftl" : forall 'n ('ord : Order).
    (vector('n, 'ord, bit), int) -> vector('n, 'ord, bit) effect pure

val sail_shiftright = "shiftr" : forall 'n ('ord : Order).
    (vector('n, 'ord, bit), int) -> vector('n, 'ord, bit) effect pure

val sail_arith_shiftright = "arith_shiftr" : forall 'n ('ord : Order).
    (vector('n, 'ord, bit), int) -> vector('n, 'ord, bit) effect pure

val sail_zeros = "zeros" : forall 'n, 'n >= 0. atom('n) -> bits('n)

val sail_ones : forall 'n, 'n >= 0. atom('n) -> bits('n)

function sail_ones(n) = not_vec(sail_zeros(n))

// Some ARM specific builtins

val slice = "slice" : forall 'n 'm 'o, 0 <= 'm & 0 <= 'n.
  (bits('m), atom('o), atom('n)) -> bits('n)

val replicate_bits = "replicate_bits" : forall 'n 'm. (bits('n), atom('m)) -> bits('n * 'm)

val slice_mask : forall 'n, 'n >= 0. (implicit('n), int, int) -> bits('n) effect pure
function slice_mask(n,i,l) =
  if l >= n then {
    sail_shiftleft(sail_ones(n), i)
  } else {
    let one : bits('n) = sail_mask(n, [bitone] : bits(1)) in
    sail_shiftleft(sub_bits(sail_shiftleft(one, l), one), i)
  }

val get_slice_int = "get_slice_int" : forall 'w. (atom('w), int, int) -> bits('w)

val set_slice_int = "set_slice_int" : forall 'w. (atom('w), int, int, bits('w)) -> int

val set_slice_bits = "set_slice" : forall 'n 'm.
  (atom('n), atom('m), bits('n), int, bits('m)) -> bits('n)

/*!
converts a bit vector of length $n$ to an integer in the range $0$ to $2^n - 1$.
 */
val unsigned = {
  ocaml: "uint",
  lem: "uint",
  interpreter: "uint",
  c: "sail_unsigned",
  coq: "uint"
} : forall 'n. bits('n) -> range(0, 2 ^ 'n - 1)

/* We need a non-empty vector so that the range makes sense */
/*!
converts a bit vector of length $n$ to an integer in the range $-2^{n-1}$ to $2^{n-1} - 1$ using twos-complement.
 */
val signed = {
  c: "sail_signed",
  _: "sint"
} : forall 'n, 'n > 0. bits('n) -> range(- (2 ^ ('n - 1)), 2 ^ ('n - 1) - 1)

overload __size = {__id, length}

$endif
