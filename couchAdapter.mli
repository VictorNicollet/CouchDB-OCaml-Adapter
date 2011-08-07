type j = Json_type.t

type func = { name : string ; min_version : int }

type request = 
  | Reduce of func array * j list
  | Map    of func array * j 

type reduce_result = [ `Ok of j array
		     | `NotDefined of int 
		     | `Error ]

type map_result    = [ `Ok of ((j * j) list) array 
		     | `NotDefined of int
		     | `Error ]

val read_request : unit -> request option
val write_map_result : map_result -> unit
val write_reduce_result : map_result -> unit

val write_request : out_channel -> request -> unit
val read_map_result : in_channel -> map_result option
val read_reduce_result : in_channel -> reduce_result option

(* ---------------------------------------------------------------- *)

exception NotDefined

val loop :
     map:(func -> j -> (j * j) list) 
  -> reduce:(func -> j list -> j)
  -> unit


(* ---------------------------------------------------------------- *)

val export_map :
     name:string 
  -> version:int
  -> body:(j -> (j * j) list)
  -> unit

val export_reduce :
     name:string 
  -> version:int
  -> body:(j list -> j)
  -> unit
  
val export : unit -> unit
