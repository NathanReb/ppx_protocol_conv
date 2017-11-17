(* Json Protocol *)
val mangle: string -> string

include Deriving_protocol.Runtime.Driver with
  type t = Yojson.Safe.json and
  type 'a flags = ?flags:[ `Mangle of (string -> string) ] -> 'a