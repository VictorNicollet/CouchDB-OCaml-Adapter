`couch-ml-adapter` is provides an adapter for transforming OCaml applications into CouchDB view servers. The programmer writes an OCaml application that exports one or more map and reduce functions using the API found in module `CouchAdapter`, and creates a CouchDB design document that specifies the application path and the name of the exported functions. The adapter server then receives evaluation requests from CouchDB and passes them to the application, and returns the result back to CouchDB.

The objective of this project is *not* to support writing OCaml code directly into views! The OCaml code *should* follow the standard build procedure, the only exception being that the `CouchAdapter` API is used to export that code and make it available to the adapter server.

## Requirements and setup

This adapter uses <a href="http://martin.jambon.free.fr/json-wheel.html"><b>json-wheel</b></a> for representing JSON values, and the build process requires <a href="http://brion.inria.fr/gallium/index.php/Ocamlbuild">OCamlBuild</a>. There are no other direct dependencies. 
Building the adapter server `runServer` is fairly straightforward: `make byte` or `make native` generates `runServer.byte` or `runServer.native` respectively. Move the resulting application to an appropriate location on your system and allow CouchDB to execute it. My suggestion is: 
	
    cp runServer.native /usr/bin/couch-ml-adapter
    chmod a+x /usr/bin/couch-ml-adapter

I will be assuming this convention for the rest of this manual. Once the server is built and installed, you need to configure CouchDB to actually use that adapter to execute OCaml views. Edit the `local.ini` configuration file of your CouchDB server (usually found in `/etc/couchdb/local.ini`) and add the following lines:

    [query_servers]
    ocaml=/usr/bin/couch-ml-adapter

Depending on your configuration, there might already be a `[query_servers]` section. If that is the case, add the second line to that section. If you have trouble configuring your query servers, <a href="http://wiki.apache.org/couchdb/View_server#The_View_Server">read the CouchDB documentation</a>.

Errors that happen while executing the adapter will appear in the CouchDB logs (usually found in `/var/log/couchdb/couch.log`).

## Architecture

### Query Servers
The CouchDB server usually evaluates map and reduce functions only when a design document containing those functions is queried by a client, by following this process:

 - If the query server configured in `local.ini` is not already running, start it.
 - Send various instructions on the query server's STDIN, such as "apply the map function F to document D"
 - Read the results on the query server's STDOUT. 
 
### The Adapter Server

The adapter server provided by this project is one such query server. When it must apply a function to a document, it does the following:

 - Determine which application provides the function. 
 - If the application is not already running, start it.
 - Send the request to the application's STDIN, read the answer on its STDOUT.
 - If the application responds with results, send these back to CouchDB.

In short, the overall architecture looks like this:

    +---------+         +------------------------+
    |         | <-----> |  Haskell Query Server  |
    |         |         +------------------------+
    |         |
    |         |         +------------------------+
    | CouchDB | <-----> | Brainfuck Query Server |
    |         |         +------------------------+
    |         | 
    |         |         +------------------------+
    |         | <-----> |                        | <-----> [ Application /home/nicollet/test ]
    +---------+         |  OCaml Adapter Server  |
                        |                        | <-----> [ Application /usr/bin/foo ]
                        +------------------------+

The programmer should therefore write an application which reads the adapter requests on STDIN, runs the requested functions on the provided documents, and sends the results back on STDOUT. All the boilerplate involved is handled by the `CouchAdapter` module, so that the actual development process you will be following is: 

 - Include any modules you might need to use in your view.
 - Define the map or reduce function as an OCaml function.
 - Register that function as being exported with `CouchAdapter.export_map` and `CouchAdapter.export_reduce`.
 - Call `CouchAdapter.export()`

### Importing From CouchDB

CouchDB references map and reduce functions in design documents, using the following syntax:

    { "_id" : "_design/..."  ,
      "language" : "...", 
      "views" : {
        "foobar" : { "map" : ... }
        "quxbaz" : { "map" : ... , "reduce" : ... }
      }
    }

In order to use the OCaml adapter, one must first set the language property to `"ocaml"`. Then, to reference the function `"extract_foo"` defined in application `/usr/bin/foo`, one would write: 

    "views" : {
      "foobar" : { "map" : ["/usr/bin/foo", 1, "extract_foo"] }
    }

The same syntax applies for reduce functions as well. The three components of the definition are **1-** the absolute path to the application that exports the function (this is how the adapter server knows what application to run), **2-** a version number discussed in the next section and **3-** the name under which the function is exported from that application.

### Function versions

For performance reasons, once an application or query server has been started, it is never shut down. This only causes problems when there's a new version of the code that needs to be deployed. The adapter server provides a versioning system which automatically detects that a function.

A CouchDB design document requests a function that is *at least* a certain version. For instance, `["/usr/bin/foo", 42, "extract_foo"]` indicates that the adapter server should find version 42 *or greater* of the function `"extract_foo"` exported by application `usr/bin/foo`. If that application is currently running *and the function is either missing or older than version 42* then the application is shut down and started anew in a completely transparent fashion.

Note that if rebooting the application *still* fails to provide an appropriate version of the function, the adapter server will report an error, which CouchDB will propagate to the client. This makes all the views inside the design document unavailable until an appropriate version of the application is deployed.

Failing to manage function versions *both in CouchDB and in the application* can lead to data inconsistencies, as different documents are processed by different versions of the same function. Only a global version change which prompts a full refresh of the view and reloads the application can ensure data consistency in the face of code changes.

## Creating a map function

A map function must follow the signature `json -> (json * json) list`: the argument is the entire document being processed, and the output is a list of `key, value` pairs being output by the map function. 

For example, suppose you already have an `User` module in your application, which is used among other things for reading and writing users to the CouchDB database: 

    type t = {
      active  : bool ;
      name    : string ;
      email   : string ;
      picture : string
    }

    let of_json = (* ... *)
    let to_json = (* ... *)

Then you can rely on that module to define a map function with the above signature, and export it using the `CouchAdapter` module:

    open Json_type

    let user_by_email json =
      try let user = User.of_json json in
          [ String user.User.email , Null ]
      with _ -> []

    let () =             

      CouchAdapter.export_map 
        ~name:"user_by_email" 
	~version:1 
	~body:user_by_email ;

      CouchAdapter.export ()

Should you decide to update the view code, make sure that you also increment the version number:

    open Json_type

    let user_by_email json =
      try let user = User.of_json json in
          if user.User.active then [ String user.User.email , Null ]
	  else []
      with _ -> []

    let () =             

      CouchAdapter.export_map 
        ~name:"user_by_email" 
	~version:2
	~body:user_by_email ;

      CouchAdapter.export ()

## Creating a reduce function

There is no distinction made between reduce and rereduce. While this causes a slight loss in functionality it also makes writing reduce functions less arduous given the OCaml type system. The signature of reduce functions is simply `json list -> json`.

For example, let's assume that an `Article` module is already defined in your main application: 

    type t = {
      title : string ;
      html  : string ;
      tags  : string list
    }
   
    let of_json = (* ... *)
    let to_json = (* ... *)

We now define a map function and a reduce function that counts how many articles are published for every tag.

    let by_tag_map json = 
      try let article = Article.of_json json in
          List.map (fun tag -> String tag , Int 1) article.Article.tags
      with _ -> []

    let by_tag_reduce json = 
      Int (List.fold_left (fun acc -> function Int i -> acc + i | _ -> acc) 0 json)

    let () = 
      CouchAdapter.export_map "by_tag-map" 1 by_tag_map ;
      CouchAdapter.export_reduce "by_tag-reduce" 1 by_tag_reduce ;
      CouchAdapter.export ()

And the CouchDB design document is as follows:

    { "_id" : "_design/article",
      "language" : "ocaml", 
      "views" : {
        "by_tag" : { "map" : ["/path/to/app", 1, "by_tag-map" ],
                     "reduce" : ["/path/to/app", 1, "by_tag-reduce" ] }
      }
    }

