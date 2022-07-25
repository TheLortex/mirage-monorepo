(*
 * Copyright (c) 2010-2014 Anil Madhavapeddy <anil@recoil.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

let src = Logs.Src.create "udp" ~doc:"Mirage UDP"
module Log = (val Logs.src_log src : Logs.LOG)

module Make (Ip : Tcpip.Ip.S) (Random : Mirage_random.S) = struct

  type ipaddr = Ip.ipaddr
  type callback = src:ipaddr -> dst:ipaddr -> src_port:int -> Cstruct.t -> unit


  type t = {
    ip : Ip.t;
    listeners : (int, callback) Hashtbl.t;
  }

  let pp_ip = Ip.pp_ipaddr

  let listen t ~port callback =
    if port < 0 || port > 65535 then
      raise (Invalid_argument (Printf.sprintf "invalid port number (%d)" port))
    else
      Hashtbl.replace t.listeners port callback

  let unlisten t ~port = Hashtbl.remove t.listeners port

  (* TODO: ought we to check to make sure the destination is relevant
     here?  Currently we process all incoming packets without making
     sure they're either unicast for us or otherwise interesting. *)
  let input t ~src ~dst buf =
    match Udp_packet.Unmarshal.of_cstruct buf with
    | Error s ->
      Log.debug (fun f ->
          f "Discarding received UDP message: error parsing: %s" s)
    | Ok ({ Udp_packet.src_port; dst_port}, payload) ->
      match Hashtbl.find_opt t.listeners dst_port with
      | None    -> ()
      | Some fn -> fn ~src ~dst ~src_port payload

  let writev ?src ?src_port ?ttl ~dst ~dst_port t bufs =
    let src_port = match src_port with
      | None   -> Randomconv.int ~bound:65535 (fun x -> Random.generate x)
      | Some p -> p
    in
    let fill_hdr buf =
      let payload_size = Cstruct.lenv bufs in
      let ph =
        Ip.pseudoheader t.ip ?src dst `UDP (payload_size + Udp_wire.sizeof_udp)
      in
      let udp_header = Udp_packet.({ src_port; dst_port; }) in
      match Udp_packet.Marshal.into_cstruct udp_header buf ~pseudoheader:ph ~payload:(Cstruct.concat bufs) with
      | Ok () -> 8
      | Error msg ->
        Logs.err (fun m -> m "error while assembling udp header: %s, ignoring" msg);
        8
    in
    try 
      Ip.write t.ip ?src dst ?ttl `UDP ~size:8 fill_hdr bufs 
    with
    |  _ -> 
      (* we're supposed to make our best effort, and we did *)
      Log.err (fun f -> f "IP module couldn't send UDP packet to %a" pp_ip dst )

  let write ?src ?src_port ?ttl ~dst ~dst_port t buf =
    writev ?src ?src_port ?ttl ~dst ~dst_port t [buf]

  let connect ip =
    Log.info (fun f -> f "UDP interface connected on %a" (Fmt.list Ip.pp_ipaddr) @@ Ip.get_ip ip);
    { ip ; listeners = Hashtbl.create 7 }

  let disconnect t =
    Log.info (fun f -> f "UDP interface disconnected on %a" (Fmt.list Ip.pp_ipaddr) @@ Ip.get_ip t.ip)

end
