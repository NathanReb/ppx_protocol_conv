(* Xml driver for ppx_protocol_conv *)
open StdLabels
open Protocol_conv.Runtime
type t = Xml.xml

let _log fmt = Printf.eprintf (fmt ^^ "\n%!")

module StringMap = Map.Make(String)

exception Protocol_error of string * t
(* Register exception printer *)
let () = Printexc.register_printer
    (function Protocol_error (s, t) -> Some (s ^ ": " ^ (Xml.to_string t))
            | _ -> None)

let raise_errorf t fmt =
  Printf.kprintf (fun s -> raise (Protocol_error (s, t))) fmt

(* We are actually able to determine if we should inline by looking at the node name.
   Alternativly, we need to wrap records into yet another level *)
let rec element_to_map m = function
  | (Xml.Element(name, _, _) as x) :: xs ->
    let m =
      let ks = try StringMap.find name m with Not_found -> [] in
      StringMap.add name (x :: ks) m
    in
    element_to_map m xs
  | _ :: xs -> element_to_map m xs
  | [] -> m

let element name t = Xml.Element (name, [], t)

let of_variant: ('a -> string * t list) -> 'a -> t = fun destruct t ->
  let (s, ts) = destruct t in
  Xml.Element("variant", [], Xml.PCData s :: ts)

let to_variant: (string * t list -> 'a) -> t -> 'a = fun constr -> function
  | Xml.Element(_, _, Xml.PCData s :: es) -> constr (s, es)
  | Xml.Element(name, _, []) as d -> raise_errorf d "No contents for variant type: %s" name
  | d -> raise_errorf d "Wrong variant data"

(* Records could be optimized by first creating a map of existing
   usable labels -> id's (at startup). Then map the input data to an
   array of lists (mutable). Then do the decoding. That would be O(n
   log n) (n = fields), but its almost the same as the current, which
   does two lookups: O(2 * n log n) = O(n log n) where n is the number
   of fields in the input data. There is hardly anypoint to
   that. Although it would be fun to create.
*)
let to_record: type a b. (t, a, b) Record_in.t -> a -> t -> b = fun spec ->
  let rec inner: type a b. (t, a, b) Record_in.t -> a -> 't -> b =
    let open Record_in in
    function
    | Cons ((field, to_value_func, default), xs) ->
      let cont = inner xs in
      fun constr t ->
        let v =
          match StringMap.find field t |> List.rev with
          | v -> `Values v
          | exception Not_found -> begin
              match default with
              | Some v -> `Default v
              | None -> `Values []
            end
        in
        let v =
          match v with
          | `Values values ->
            let arg = match values with
              | [ Xml.Element (name, _, xs) ] -> Xml.Element (name, ["record", "unwrapped"], xs)
              | [ Xml.PCData _ as d ] -> d
              | xs -> Xml.Element (field, [], xs)
            in
            to_value_func arg
          | `Default v -> v
        in
        cont (constr v) t
    | Nil -> fun a _t -> a
  in
  let f = inner spec in
  fun constr -> function
    | Xml.Element (_, _, t) ->
      let m = StringMap.empty in
      f constr (element_to_map m t)
    | e -> raise_errorf e "Not a record superstruture"

let of_record: _ Record_out.t -> t = fun l ->
  let rec inner: _ Record_out.t -> (string * t) list = function
    | Record_out.Cons ((_, v, _, Some default), xs) when v = default -> inner xs
    | Record_out.Cons ((k, v, to_t, _), xs) -> (k, to_t v) :: inner xs
    | Record_out.Nil -> []
  in
  let assoc = inner l in
  List.map ~f:(
    function
    | (field, Xml.Element ("record", attrs, xs)) -> [Xml.Element (field, attrs, xs)]
    | (field, Xml.Element ("variant", attrs, xs)) -> [Xml.Element (field, attrs, xs)]
    | (field, Xml.Element ("__option", attrs, xs)) -> [Xml.Element (field, attrs, xs)]
    | (field, Xml.Element (_, _, xs)) ->
      List.map ~f:(function
          | Xml.Element(_, attrs, xs) ->
            Xml.Element(field, attrs, xs)
          | PCData _ as p -> Xml.Element(field, [], [p])
        ) xs (* why xs here. Or do we need to extend the option one level *)
    | (field, e) -> raise_errorf e "Must be an element: %s" field
  ) assoc
  |> List.flatten |> element "record"


let to_tuple = to_record

let of_tuple l =
  let open Record_out in
  List.fold_right ~init:(Nil)
    ~f:(fun (k, t) acc -> (k, t, (fun t -> t), None) ^:: acc)
    l
  |> of_record

let to_option: (t -> 'a) -> t -> 'a option = fun to_value_fun t ->
  (* Not allowed to throw out the unwrap. *)
  match t with
  | Xml.Element (_, [_, "unwrapped"], [])
  | Xml.Element (_, _, [])
  | Xml.Element (_, _, [ PCData ""] ) ->
    None
  | Xml.Element (_, [_, "unwrapped"], [ (Element ("__option", _, _) as t)])
  (*  | Xml.Element (_, [_, "unwrapped"], [ t ]) *)
  | Xml.Element ("__option", _, [t])
  | t ->
    Some (to_value_fun t)

(* Some Some None ->
   Some Some Some v -> v
*)

let of_option: ('a -> t) -> 'a option -> t = fun of_value_fun v ->
  let t = match v with
    | None ->
      Xml.Element ("__option", [], [])
    | Some x -> begin
      match of_value_fun x with
        | (Xml.Element ("__option", _, _) as t) ->
          Xml.Element ("__option", [], [t])
        | t ->
          t
    end
  in
  t

let to_ref: (t -> 'a) -> t -> 'a ref = fun to_value_fun t ->
  let v = to_value_fun t in
  ref v

let of_ref: ('a -> t) -> 'a ref -> t = fun of_value_fun v ->
  of_value_fun !v


(** If the given list has been unwrapped since its part of a record, we "rewrap it". *)
let to_list: (t -> 'a) -> t -> 'a list = fun to_value_fun -> function
  | Xml.Element (_, [_, "unwrapped"], _) as elm ->
    (* If the given list has been unwrapped since its part of a record, we "rewrap it". *)
    [ to_value_fun elm ]
  | Xml.Element (_, _, ts) ->
    List.map ~f:(fun t -> to_value_fun t) ts
  | e -> raise_errorf e "Must be an element type"

let of_list: ('a -> t) -> 'a list -> t = fun of_value_fun vs ->
  Xml.Element("l", [], List.map ~f:(fun v -> of_value_fun v) vs)

let to_array: (t -> 'a) -> t -> 'a array = fun to_value_fun t ->
  to_list to_value_fun t |> Array.of_list

let of_array: ('a -> t) -> 'a array -> t = fun of_value_fun vs ->
  of_list of_value_fun (Array.to_list vs)

let to_lazy_t: (t -> 'a) -> t -> 'a lazy_t = fun to_value_fun t -> Lazy.from_fun (fun () -> to_value_fun t)

let of_lazy_t: ('a -> t) -> 'a lazy_t -> t = fun of_value_fun v ->
  Lazy.force v |> of_value_fun


let of_value to_string v = Xml.Element ("p", [], [ Xml.PCData (to_string v) ])
let to_value type_name of_string = function
  | Xml.Element(_, _, []) -> of_string ""
  | Xml.Element(_, _, [PCData s]) -> of_string s
  | Xml.Element(name, _, _) as e -> raise_errorf e "Primitive value expected in node: %s for %s" name type_name
  | Xml.PCData _ as e -> raise_errorf e "Primitive type not expected here when deserializing %s" type_name

let to_bool = to_value "bool" bool_of_string
let of_bool = of_value string_of_bool

let to_int = to_value "int" int_of_string
let of_int = of_value string_of_int

let to_int32 = to_value "int32" Int32.of_string
let of_int32 = of_value Int32.to_string

let to_int64 = to_value "int64" Int64.of_string
let of_int64 = of_value Int64.to_string

let to_float = to_value "float" float_of_string
let of_float = of_value string_of_float

let to_string = to_value "string" (fun x -> x)
let of_string = of_value (fun x -> x)

let to_char t = to_value "char" (function s when String.length s = 1 -> s.[0]
                                        | _ -> raise (Protocol_error ("Expected char", t))) t
let of_char = of_value (fun c -> (String.make 1 c))



let to_unit = to_value "unit" (function "()" -> () | _ -> failwith "expected unit")
let of_unit = of_value (fun () -> "()")

(*
let to_unit t = to_tuple Nil () t
let of_unit () = of_tuple []
*)
    (*
let to_unit = function Xml.Element (_, _, [ PCData "unit" ]) -> ()
                     | e -> raise_errorf e "Unit must be 'unit'"

let of_unit () = Xml.Element ("u", [], [ PCData "unit" ])
*)
let of_xml_light t = t
let to_xml_light t = t
