exception NotDefined

type j = Json_type.t

type func = { name : string ; min_version : int }

type request = 
  | Reduce of func array * j list
  | Map    of func array * j 

type reduce_result = [ `Ok of j array | `NotDefined of int | `Error ]

type map_result    = [ `Ok of ((j * j) list) array | `NotDefined of int | `Error ]

let read_request  () = try Some (Marshal.from_channel stdin) with _ -> None
let write_request channel request = Marshal.to_channel channel request [Marshal.No_sharing] ; flush channel

let read_map_result  channel = try Some (Marshal.from_channel channel) with _ -> None
let write_map_result result  = Marshal.to_channel stdout result [Marshal.No_sharing] ; flush stdout

let read_reduce_result  channel = try Some (Marshal.from_channel channel) with _ -> None
let write_reduce_result result  = Marshal.to_channel stdout result [Marshal.No_sharing] ; flush stdout

exception InternalNotDefined of int

let rec loop ~map ~reduce =   

  match read_request () with
    | Some (Map (funcs, doc)) -> 
      
      let result =
	try
	  `Ok (
	    Array.mapi (fun i f ->
	      try map f doc with NotDefined -> raise (InternalNotDefined i)
	    ) funcs
	  )
	with 
	  | InternalNotDefined i -> `NotDefined i
	  | _ -> `Error
      in
      
      write_map_result result ; loop ~map ~reduce
	  
      | Some (Reduce (funcs, list)) ->
	
	let result = 
	  try 
	    `Ok (
	      Array.mapi (fun i f ->
		try reduce f list with NotDefined -> raise (InternalNotDefined i)
	      ) funcs
	    )
	  with 
	    | InternalNotDefined i -> `NotDefined i
	    | _ -> `Error
	in

	write_reduce_result result ; loop ~map ~reduce

      | None -> ()

type export = {
  map : (string, int * (j -> (j * j) list)) Hashtbl.t ;
  reduce : (string, int * (j list -> j)) Hashtbl.t
}

let exported = {
  map = Hashtbl.create 10 ;
  reduce = Hashtbl.create 10
}

let export_map ~name ~version ~body = 
  Hashtbl.add exported.map name (version,body)

let export_reduce ~name ~version ~body = 
  Hashtbl.add exported.reduce name (version,body)

let export () = 
  loop
    ~map:(fun func -> 
      try let version, body = Hashtbl.find exported.map func.name in
	  if version < func.min_version then raise NotDefined else body
      with Not_found -> raise NotDefined
    )
    ~reduce:(fun func -> 
      try let version, body = Hashtbl.find exported.reduce func.name in
	  if version < func.min_version then raise NotDefined else body
      with Not_found -> raise NotDefined
    )
