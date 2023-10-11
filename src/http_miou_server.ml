open Http_miou_unix

module TLS_for_httpaf = struct
  include TLS

  let shutdown flow _ = Miou_unix.disown flow.flow
end

module A = Runtime.Make (TLS_for_httpaf) (Httpaf.Server_connection)
module B = Runtime.Make (TCP) (Httpaf.Server_connection)
module C = Runtime.Make (TLS) (H2.Server_connection)

[@@@warning "-34"]

type config = [ `V1 of Httpaf.Config.t | `V2 of H2.Config.t ]
type flow = [ `Tls of TLS.t | `Tcp of Miou_unix.file_descr ]

type error =
  [ `V1 of Httpaf.Server_connection.error
  | `V2 of H2.Server_connection.error
  | `Protocol of string ]

let pp_error ppf = function
  | `V1 `Bad_request -> Fmt.string ppf "Bad HTTP/1.1 request"
  | `V1 `Bad_gateway -> Fmt.string ppf "Bad HTTP/1.1 gateway"
  | `V1 `Internal_server_error | `V2 `Internal_server_error ->
      Fmt.string ppf "Internal server error"
  | `V1 (`Exn exn) | `V2 (`Exn exn) ->
      Fmt.pf ppf "Got an unexpected exception: %S" (Printexc.to_string exn)
  | `V2 `Bad_request -> Fmt.string ppf "Bad H2 request"
  | `Protocol msg -> Fmt.string ppf msg

let src = Logs.Src.create "http-miou-server"

module Log = (val Logs.src_log src : Logs.LOG)
module Method = H2.Method
module Headers = H2.Headers
module Status = H2.Status

exception Body_already_sent

type request =
  { meth : Method.t; target : string; scheme : string; headers : Headers.t }

type response = { status : Status.t; headers : Headers.t }

let response_to_httpaf response =
  let headers = Httpaf.Headers.of_list (H2.Headers.to_list response.headers) in
  let status =
    match response.status with
    | #Httpaf.Status.t as status -> status
    | _ -> invalid_arg "Invalid HTTP/1.1 status"
  in
  Httpaf.Response.create ~headers status

let _response_to_h2 response =
  H2.Response.create ~headers:response.headers response.status

let request_from_httpaf ~scheme { Httpaf.Request.meth; target; headers; _ } =
  let headers = Headers.of_list (Httpaf.Headers.to_list headers) in
  { meth; target; scheme; headers }

type stream =
  { write_string : ?off:int -> ?len:int -> string -> unit
  ; write_bigstring : ?off:int -> ?len:int -> Bigstringaf.t -> unit
  ; close : unit -> unit
  }

type _ Effect.t += String : response * string -> unit Effect.t
type _ Effect.t += Bigstring : response * Bigstringaf.t -> unit Effect.t
type _ Effect.t += Stream : response -> stream Effect.t

let string ~status ?(headers = Headers.empty) str =
  let response = { status; headers } in
  Effect.perform (String (response, str))

let bigstring ~status ?(headers = Headers.empty) bstr =
  let response = { status; headers } in
  Effect.perform (Bigstring (response, bstr))

let stream ?(headers = Headers.empty) status =
  let response = { status; headers } in
  Effect.perform (Stream response)

type error_handler =
  ?request:request -> error -> (H2.Headers.t -> stream) -> unit

type handler = request -> unit

let pp_sockaddr ppf = function
  | Unix.ADDR_UNIX name -> Fmt.pf ppf "<%s>" name
  | Unix.ADDR_INET (inet_addr, port) ->
      Fmt.pf ppf "%s:%d" (Unix.string_of_inet_addr inet_addr) port

let rec basic_handler ~exnc =
  let open Effect.Shallow in
  let fail k = discontinue_with k Body_already_sent (basic_handler ~exnc) in
  let retc = Fun.id in
  let effc :
      type c. c Effect.t -> ((c, 'a) Effect.Shallow.continuation -> 'b) option =
    function
    | String _ | Bigstring _ | Stream _ ->
        Log.err (fun m -> m "the user wants to write to the peer a second time");
        Some fail
    | _ -> None
  in
  { retc; exnc; effc }

let httpaf_handler ~sockaddr ~scheme ~protect:{ Runtime.protect } ~orphans
    ~handler reqd =
  let open Httpaf in
  let open Effect.Shallow in
  let retc = Fun.id in
  let exnc = protect ~orphans (Reqd.report_exn reqd) in
  let effc :
      type c. c Effect.t -> ((c, 'a) Effect.Shallow.continuation -> 'b) option =
    function
    | String (response, str) ->
        let response = response_to_httpaf response in
        Log.debug (fun m -> m "write a http/1.1 response and its body");
        protect ~orphans (Reqd.respond_with_string reqd response) str;
        let handler = basic_handler ~exnc in
        Some (fun k -> continue_with k () handler)
    | Stream response ->
        let response = response_to_httpaf response in
        let body =
          protect ~orphans (Reqd.respond_with_streaming reqd) response
        in
        let write_string ?off ?len str =
          protect ~orphans (Body.write_string body ?off ?len) str
        in
        let write_bigstring ?off ?len bstr =
          protect ~orphans (Body.write_bigstring body ?off ?len) bstr
        in
        let close () = protect ~orphans Body.close_writer body in
        let stream = { write_string; write_bigstring; close } in
        let handler = basic_handler ~exnc in
        Some (fun k -> continue_with k stream handler)
    | _ -> None
  in
  let fn request =
    let request = request_from_httpaf ~scheme request in
    handler request;
    Runtime.terminate orphans;
    Log.debug (fun m -> m "the handler for %a has ended" pp_sockaddr sockaddr)
  in
  continue_with (fiber fn) (Reqd.request reqd) { retc; exnc; effc }

let rec clean orphans =
  match Miou.care orphans with
  | Some (Some prm) ->
      Miou.await_exn prm;
      clean orphans
  | Some None | None -> ()

let default_error_handler ?request:_ _err _respond = ()

let accept_or_stop ?stop file_descr =
  match stop with
  | None -> `Accept (Miou_unix.accept file_descr)
  | Some stop -> (
      let accept =
        Miou.call_cc ~give:[ Miou_unix.owner file_descr ] @@ fun () ->
        let file_descr', sockaddr = Miou_unix.accept file_descr in
        Miou_unix.disown file_descr;
        `Accept (Miou_unix.transfer file_descr', sockaddr)
      in
      let rec go () = if Atomic.get stop then `Stop else go (Miou.yield ()) in
      Miou.await_first [ accept; Miou.call_cc go ] |> function
      | Ok value -> value
      | Error exn -> raise exn)

let clear ?stop ?(config = Httpaf.Config.default)
    ?error_handler:(user's_error_handler = default_error_handler) ~handler
    file_descr =
  let read_buffer_size = config.Httpaf.Config.read_buffer_size in
  let rec go orphans file_descr =
    Log.debug (fun m ->
        m "waiting for a new connection or a stop signal from the user");
    match accept_or_stop ?stop file_descr with
    | `Stop ->
        Log.debug (fun m -> m "terminate the clear http server");
        Runtime.terminate orphans
    | `Accept (file_descr', sockaddr) ->
        Log.debug (fun m -> m "receive a new client: %a" pp_sockaddr sockaddr);
        clean orphans;
        let give = [ Miou_unix.owner file_descr' ] in
        let _ =
          Miou.call ~orphans ~give @@ fun () ->
          let orphans = Miou.orphans () in
          let rec error_handler ?request err respond =
            let { Runtime.protect }, _, _ = Lazy.force process in
            let request =
              Option.map (request_from_httpaf ~scheme:"http") request
            in
            let respond hdrs =
              let open Httpaf in
              let hdrs = Httpaf.Headers.of_list (H2.Headers.to_list hdrs) in
              let body = protect ~orphans respond hdrs in
              let write_string ?off ?len str =
                protect ~orphans (Body.write_string body ?off ?len) str
              in
              let write_bigstring ?off ?len bstr =
                protect ~orphans (Body.write_bigstring body ?off ?len) bstr
              in
              let close () = protect ~orphans Body.close_writer body in
              { write_string; write_bigstring; close }
            in
            match err with
            | `Exn (Runtime.Flow msg) ->
                user's_error_handler ?request (`Protocol msg :> error) respond
            | err -> user's_error_handler ?request (`V1 err) respond
          and request_handler reqd =
            let protect, _, _ = Lazy.force process in
            httpaf_handler ~sockaddr ~scheme:"http" ~protect ~orphans ~handler
              reqd
          and conn =
            lazy
              (Httpaf.Server_connection.create ~config ~error_handler
                 request_handler)
          and process =
            lazy
              (B.run (Lazy.force conn) ~give ~disown:Miou_unix.disown
                 ~read_buffer_size file_descr')
          in
          let _, prm, close = Lazy.force process in
          Log.debug (fun m -> m "the http/1.1 server connection is launched");
          let _result = Miou.await prm in
          Log.debug (fun m ->
              m "clean everything for the client %a" pp_sockaddr sockaddr);
          Runtime.terminate orphans;
          (* TODO(dinosaure): are you sure? [httpaf_handler] already did it. *)
          close ();
          Log.debug (fun m ->
              m "the process for %a is cleaned" pp_sockaddr sockaddr)
        in
        Miou_unix.disown file_descr';
        go orphans file_descr
  in
  go (Miou.orphans ()) file_descr