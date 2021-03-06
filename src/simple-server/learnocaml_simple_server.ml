(* This file is part of Learn-OCaml.
 *
 * Copyright (C) 2016 OCamlPro.
 *
 * Learn-OCaml is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * Learn-OCaml is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>. *)

let static_dir = ref (Filename.concat (Sys.getcwd ()) "www")

let sync_dir = ref (Filename.concat (Sys.getcwd ()) "sync")

let port = ref 8080

let args = Arg.align @@
  [ "-static-dir", Arg.Set_string static_dir,
    "PATH where static files should be found (./www)" ;
    "-sync-dir", Arg.Set_string sync_dir,
    "PATH where sync tokens are stored (./sync)" ;
    "-port", Arg.Set_int port,
    "PORT the TCP port (8080)" ]

open Lwt.Infix

let read_static_file path =
  let rec shorten path =
    let rec resolve acc = function
      | [] -> List.rev acc
      | "." :: rest -> resolve acc rest
      | ".." :: rest ->
          begin match acc with
            | [] -> resolve [] rest
            | _ :: acc -> resolve acc rest end
      | name :: rest -> resolve (name :: acc) rest in
    resolve [] path in
  let path =
    String.concat Filename.dir_sep (!static_dir :: shorten path) in
  Lwt_io.(with_file ~mode: Input path (fun chan -> read chan))

let alphabet =
  "ABCDEFGH1JKLMNOPORSTUVWXYZO1Z34SG1B9"
let visually_equivalent_alphabet =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

let parse_token =
  let table = Array.make 256 None in
  String.iter
    (fun c -> Array.set table (Char.code c) (Some c))
    visually_equivalent_alphabet ;
  let translate part =
    String.map (fun c ->
        match Array.get table (Char.code c) with
        | None -> failwith "bad token character"
        | Some c -> c)
      part in
  fun token ->
    if String.length token <> 15 then
      failwith "bad token length"
    else if String.get token 3 <> '-'
         || String.get token 7 <> '-'
         || String.get token 11 <> '-' then
      failwith "bad token format"
    else
      List.map translate
        [ String.sub token 0 3 ;
          String.sub token 4 3 ;
          String.sub token 8 3 ;
          String.sub token 12 3 ]

let retrieve token =
  let path =
    String.concat Filename.dir_sep (!sync_dir :: parse_token token) in
  Lwt_io.(with_file ~mode: Input path (fun chan -> read chan))

let store token contents =
  let path =
    String.concat Filename.dir_sep (!sync_dir :: parse_token token) in
  Lwt_io.(with_file ~mode: Output path (fun chan -> write chan contents))

let gimme () =
  let rec next () =
    let rand () = String.get alphabet (Random.int (String.length alphabet)) in
    let part () = String.init 3 (fun _ -> rand ()) in
    let token = [ part () ; part () ; part () ; part () ] in
    if Sys.file_exists (String.concat Filename.dir_sep (!sync_dir :: token)) then
      next ()
    else
      let rec create acc path =
        begin if Sys.file_exists acc then
            if Sys.is_directory acc then
              Lwt.return ()
            else
              Lwt.fail (Failure "bad sync directory structure")
          else
            Lwt_unix.mkdir acc 0o750
        end >>= fun () ->
        match path with
        | [] -> assert false
        | [ file ] ->
            let fn = (Filename.concat acc file) in
            Lwt_io.(with_file ~mode: Output fn (fun chan -> write chan "")) >>= fun () ->
            Lwt.return (String.concat "-" token)
        | dir :: path ->
            create (Filename.concat acc dir) path in
      create !sync_dir token in
  next ()

let launch () =
  let open Lwt in
  let open Cohttp in
  let open Cohttp_lwt_unix in
  let callback _ req body =
    let path = Uri.path (Request.uri req) in
    let path = Stringext.split ~on:'/' path in
    let path = List.filter ((<>) "") path in
    let respond_static path =
      catch
        (fun () ->
           read_static_file path >>= fun body ->
           let headers =
             try
               Cohttp.Header.init_with "Content-Type"
                 (Magic_mime.lookup (List.fold_left (fun _ r -> r) "" path))
             with _ -> Cohttp.Header.init () in
           Server.respond_string ~headers ~status:`OK ~body ())
        (fun _ ->
           Server.respond_not_found ()) in
    match Request.meth req, path with
    | `GET, [] ->
        respond_static [ "index.html" ]
    | `GET, [ "sync" ; "gimme" ] ->
        gimme () >>= fun token ->
        let body = Printf.sprintf "{\"token\":\"%s\"}" token in
        Server.respond_string ~status:`OK ~body ()
    | `GET, [ "sync" ; token ] ->
        retrieve token >>= fun body ->
        Server.respond_string ~status:`OK ~body ()
    | `POST, [ "sync" ; token ] ->
        Cohttp_lwt_body.to_string body >>= fun body ->
        store token body >>= fun () ->
        Server.respond_string ~status:`OK ~body: "Stored." ()
    | `GET, path -> respond_static path
    | _ -> Server.respond_error ~status: `Bad_request ~body: "Bad request" () in
  Random.self_init () ;
  Server.create
    ~on_exn: (function
        | Unix.Unix_error(Unix.EPIPE, "write", "") -> ()
        | exn -> raise exn)
    ~mode:(`TCP (`Port !port)) (Server.make ~callback ())

let () =
  Arg.parse args
    (fun _ -> raise (Arg.Bad "unexpected argument"))
    "Usage: learnocaml-simple-server [options]" ;
  ignore (Lwt_main.run (launch ()))
