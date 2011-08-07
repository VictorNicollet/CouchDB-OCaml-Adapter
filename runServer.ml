open CouchAdapter
open Json_type

let retries = 5

module Server : sig

  val map_query : j -> string -> func array -> ((j * j) list) array

  val reduce_query : j list -> string -> func array -> j array

end = struct

  let servers = Hashtbl.create 2

  let do_query read_result funcs command request = 

    let rec retry attempts = 

      let (server_output, server_input) = 
	try Hashtbl.find servers command with Not_found ->
	  let server = Unix.open_process command in
	  Hashtbl.add servers command server ; server
      in

      write_request server_input request ;
      
      
      match read_result server_output with 
	| Some `Error -> failwith ("Command `" ^ command ^ "` reported an error.")
	| None        -> failwith ("Command `" ^ command ^ "` did not output any data.")

	| Some (`Ok json_array) -> 

	  begin 
	    if Array.length json_array <> Array.length funcs then
	      failwith ("Command `" ^ command ^ "` returned incorrect number of responses.") ;
	    
	    json_array
	  end

	| Some (`NotDefined i) -> 

	  begin 
	    if attempts = 1 then 
	      let name = 
		try funcs.(i).name 
		with _ -> failwith "Command `" ^ command ^ "` : unknown function was missing"
	      in
	      failwith ("Command `" ^ command ^ "` could not find requested function " ^ name)
	    else 
	      begin 
		( try ignore (Unix.close_process (server_output, server_input)) with _ -> ()) ;
		Hashtbl.remove servers command ;
		retry (attempts - 1) 
	      end
	  end
	    
    in

    retry (retries + 1)

  let map_query doc command funcs = 
    do_query read_map_result funcs command (Map (funcs,doc))

  let reduce_query values command funcs = 
    do_query read_reduce_result funcs command (Reduce (funcs,values))

end 

module Functions = struct

  class functions = object

    val         commands : (string, func array * int) Hashtbl.t = Hashtbl.create 10
    val mutable values   : (int * int) list = []
      
    method add command func = 
      
      let (funcs, pos) =
	try Hashtbl.find commands command with Not_found -> ( [| |], Hashtbl.length commands )
      in
      
      let num_funcs = Array.length funcs in 
      let funcs =
	Array.init (num_funcs + 1) (fun i -> if i < num_funcs then funcs.(i) else func) 
      in
      
      Hashtbl.remove commands command ;
      Hashtbl.add commands command ( funcs, pos ) ;
      values <- ( pos, num_funcs ) :: values

    method call : 'a. (string -> func array -> 'a array) -> 'a list = fun query ->  
      let results = Array.make (Hashtbl.length commands) [| |] in
      
      Hashtbl.iter (fun command (funcs, pos) ->
	let result  = query command funcs in
	results.(pos) <- result
      ) commands ;
      
      List.rev_map (fun (cmd,fn) -> results.(cmd).(fn)) values
		
    method reset  =
      Hashtbl.clear commands ;
      values <- [] 

  end

  let global = new functions 

  let add = global # add

  let call json = global # call (Server.map_query json) 

  let reset () = global # reset

end

module Parse = struct

  let parse_function = function
    | Array [ String command ;
	      Int    min_version ;
	      String name ] ->
      
      command, { min_version ; name }
	
    | _ -> failwith "Incorrect function format"

  let parse_functions json = 
    let f = new Functions.functions in 
    match json with 
      | Array funcs ->
	
	List.iter (fun json ->
	  let command, func = parse_function json in 
	  f # add command func
	) funcs ;
	
	f
	  
      | _ -> failwith "Incorrect function list format" 		    

  let parse_reduce_lines = function
    | Array lines -> 
      
      List.map (function 
	| Array [ _ ; value ] -> value 
	| _ -> failwith "Incorrect map result format"
      ) lines
	
    | _ -> failwith "Incorrect map result format"

  let parse_rereduce_lines = function
    | Array lines -> lines
    | _ -> failwith "Incorrect reduce result format"

end

module API = struct
      
  (* Reset the list of available functions *)
  let reset () = 
    Functions.reset () ;
    Bool true

  (* Add a function to the list of map functions to be run on every document. *)
  let add_fun json = 
    let command, func = Parse.parse_function json in 
    Functions.add command func ;
    Bool true 

  (* Run all the map functions on a document. *)
  let map_doc json = 
    let results = Functions.call json in
    Build.list
      (Build.list
	 (fun (k,v) -> Array [ k ; v ]))
      results

  (* Apply a first-reduce list of functions *)
  let reduce funcs lines = 
    let lines = Parse.parse_reduce_lines lines in
    let funcs = Parse.parse_functions funcs in
    Array [ Bool true ; Array (funcs # call (Server.reduce_query lines)) ]

  (* Apply a rereduce list of functions *)
  let rereduce funcs lines = 
    let lines = Parse.parse_rereduce_lines lines in 
    let funcs = Parse.parse_functions funcs in 
    Array [ Bool true ; Array (funcs # call (Server.reduce_query lines)) ]

end

let process line = 
  try 
    let json = Json_io.json_of_string ~recursive:true line in
    match json with 
      | Array ( String "reset" :: _ ) -> API.reset ()
      | Array [ String "add_fun" ; json ] -> API.add_fun json 
      | Array [ String "map_doc" ; json ] -> API.map_doc json
      | Array [ String "reduce" ; funcs ; lines ] -> API.reduce funcs lines
      | Array [ String "rereduce" ; funcs ; lines ] -> API.rereduce funcs lines
      | _ -> failwith "Incorect operation"
  with 
    | Failure f -> Object [ "error", String "Failure" ;
			    "reason", String f ]

    | exn -> Object [ "error", String "Exception" ;
		      "reason", String (Printexc.to_string exn) ]

let rec loop () = 
  let line = read_line () in
  let json = process line in 
  let line = Json_io.string_of_json ~recursive:true ~compact:true json in
  print_endline line ;
  loop () 

let _ = loop () 

  
