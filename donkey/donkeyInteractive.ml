(* Copyright 2001, 2002 b8_bavard, b8_fee_carabine, INRIA *)
(*
    This file is part of mldonkey.

    mldonkey is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    mldonkey is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with mldonkey; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
*)

open Md4

open CommonShared
open CommonServer
open CommonResult
open CommonClient
open CommonUser
open CommonInteractive
open CommonNetwork
open GuiTypes
open CommonTypes
open CommonComplexOptions
open CommonFile
open DonkeySearch
open Options
open DonkeyMftp
open DonkeyProtoCom
open DonkeyServers
open BasicSocket
open TcpBufferedSocket
open DonkeyOneFile
open DonkeyFiles
open DonkeyComplexOptions
open DonkeyTypes
open DonkeyOptions
open DonkeyGlobals
open DonkeyClient
open CommonGlobals
open CommonOptions
open DonkeyStats
  
let result_name r =
  match r.result_names with
    [] -> None
  | name :: _ -> Some name

      
let reconnect_all file =
  DonkeyOvernet.recover_file file;
  
(* This is expensive, no ? *)
  DonkeySources1.S.reschedule_sources file;
  List.iter (fun s ->
      match s.server_sock, server_state s with
      | Some sock, (Connected _ | Connected_downloading) ->
          s.server_waiting_queries <- file :: s.server_waiting_queries
      | _ -> ()
  ) (connected_servers())
    
let forget_search s =  
  if !xs_last_search = s.search_num then begin
      xs_last_search := (-1);
      xs_servers_list := [];
    end

  
(*  
let save_as file real_name =
(*
Source of bug ...
Unix2.safe_mkdir (Filename.dirname real_name);
*)
  file_commit (as_file file.file_file);
  Unix32.close (file_fd file);
  let old_name = file_disk_name file in
  Printf.printf "\nMOVING %s TO %s\n" old_name real_name; 
  print_newline ();
  (try 
      let new_name = rename_to_incoming_dir old_name real_name in
      change_hardname file new_name
    with e -> 
        Printf.eprintf "Error in rename %s (src [%s] dst [%s])"
          (Printexc2.to_string e) old_name real_name; 
        print_newline ();
  )
  ;
  remove_file_clients file;
  file.file_changed <- FileInfoChange;
(*  !file_change_hook file *)
  ()
  
let save_file file name =
  let real_name = Filename.concat !!incoming_directory (canonize_basename name)
    in
  save_as file real_name;
  file_commit (as_file file.file_file)
*)
  
  
let load_server_met filename =
  try
    let module S = DonkeyImport.Server in
    let s = File.to_string filename in
    let ss = S.read s in
    List.iter (fun r ->
        try
          let server = check_add_server r.S.ip r.S.port in
          List.iter (fun tag ->
              match tag with
                { tag_name = "name"; tag_value = String s } -> 
                  server.server_name <- s;
              |  { tag_name = "description" ; tag_value = String s } ->
                  server.server_description <- s
              | _ -> ()
          ) r.S.tags
        with _ -> ()
    ) ss;
    List.length ss
  with e ->
      Printf.printf "Exception %s while loading %s" (Printexc2.to_string e)
      filename;
      print_newline ();
      0

let already_done = Failure "File already downloaded"
      
let really_query_download filenames size md4 location old_file absents =
  begin
    try
      let file = Hashtbl.find files_by_md4 md4 in
      if file_state file = FileDownloaded then 
        raise already_done;
    with Not_found -> ()
  end;
  
  List.iter (fun file -> 
      if file.file_md4 = md4 then raise already_done) 
  !current_files;

  let temp_file = Filename.concat !!temp_directory (Md4.to_string md4) in
  begin
    match old_file with
      None -> ()
    | Some filename ->
        if Sys.file_exists filename && not (
            Sys.file_exists temp_file) then
          (try 
              if !verbose then begin
                  Printf.printf "Renaming from %s to %s" filename
                    temp_file; print_newline ();
                end;
              Unix2.rename filename temp_file;
              Unix.chmod temp_file 0o644;
              with e -> 
                Printf.printf "Could not rename %s to %s: exception %s"
                  filename temp_file (Printexc2.to_string e);
                print_newline () );        
  end;
  
  let file = new_file FileDownloading temp_file md4 size true in
  begin
    match absents with
      None -> ()
    | Some absents -> 
        let absents = Sort.list (fun (p1,_) (p2,_) -> p1 <= p2) absents in
        file.file_absent_chunks <- absents;
  end;
  
  let other_names = DonkeyIndexer.find_names md4 in
  let filenames = List.fold_left (fun names name ->
        if List.mem name names then names else name :: names
    ) filenames other_names in 
  file.file_filenames <- file.file_filenames @ filenames ;
  update_best_name file;

  DonkeyOvernet.recover_file file;
  
  current_files := file :: !current_files;
(*  !file_change_hook file; *)
  set_file_size file (file_size file);
  List.iter (fun s ->
      match s.server_sock with
        None -> () (* assert false !!! *)
      | Some sock ->
          query_location file sock
  ) (connected_servers());

  (try
      let servers = Hashtbl.find_all udp_servers_replies file.file_md4 in
      List.iter (fun s ->
          udp_server_send s (DonkeyProtoServer.QueryLocationUdpReq file.file_md4)
      ) servers
    with _ -> ());
  
  (match location with
      None -> ()
    | Some num ->
        let c = client_find num in
        client_connect c
        (*
        try 
          let c = find_client num in
          (match c.client_kind with
              Indirect_location -> 
                if not (Intmap.mem c.client_num file.file_indirect_locations) then
                  file.file_indirect_locations <- Intmap.add c.client_num c
                    file.file_indirect_locations
            
            | _ -> 
                if not (Intmap.mem c.client_num file.file_known_locations) then
                  new_known_location file c
          );
          if not (List.memq file c.client_files) then
            c.client_files <- file :: c.client_files;
          match client_state c with
            NotConnected -> 
              connect_client !!client_ip [file] c
          | Connected_busy | Connected_idle | Connected_queued ->
              begin
                match c.client_sock with
                  None -> ()
                | Some sock -> 
                    DonkeyClient.query_files c sock [file]
              end
          | _ -> ()
with _ -> ()
*)
  )
        
let query_download filenames size md4 location old_file absents force =
  if not force then
    List.iter (fun m -> 
        if m = md4 then begin
            let r = try
                DonkeyIndexer.find_result md4
              with _ -> 
(* OK, we temporary create a result corresponding to the
file that should have been download, but has already been downloaded *)
                  
                  
                  let r = { 
                      result_num = 0;
                      result_network = network.network_num;
                      result_md4 = md4;
                      result_names = filenames;
                      result_size = size;
                      result_tags = [];
                      result_type = "";
                      result_format = "";
                      result_comment = "";
                      result_done = false;
                    } in
                  DonkeyIndexer.index_result_no_filter r 
            in
            aborted_download := Some (result_num (as_result r.result_result));
            raise already_done
          end) 
    !!old_files;
  really_query_download filenames size md4 location old_file absents

let result_download rs filenames force =
  let r = Store.get store rs.result_index in
  query_download filenames r.result_size r.result_md4 None None None force
  
let load_prefs filename = 
  try
    let module P = DonkeyImport.Pref in
    let s = File.to_string filename in
    let t = P.read s in
    t.P.client_tags, t.P.option_tags
  with e ->
      Printf.printf "Exception %s while loading %s" (Printexc2.to_string e)
      filename;
      print_newline ();
      [], []
      
let import_temp temp_dir =  
  let list = Unix2.list_directory temp_dir in
  let module P = DonkeyImport.Part in
  List.iter (fun filename ->
      try
        if Filename2.last_extension filename = ".part" then
          let filename = Filename.concat temp_dir filename in
          let met = filename ^ ".met" in
          if Sys.file_exists met then
            let s = File.to_string met in
            let f = P.read s in
            let filenames = ref [] in
            let size = ref Int64.zero in
            List.iter (fun tag ->
                match tag with
                  { tag_name = "filename"; tag_value = String s } ->
                    Printf.printf "Import Donkey %s" s; 
                    print_newline ();
                    
                    filenames := s :: !filenames;
                | { tag_name = "size"; tag_value = Uint64 v } ->
                    size := v
                | _ -> ()
            ) f.P.tags;
            query_download !filenames !size f.P.md4 None 
              (Some filename) (Some (List.rev f.P.absents)) true;
      
      with _ -> ()
  ) list
  
  
let import_config dirname =
  ignore (load_server_met (Filename.concat dirname "server.met"));
  let ct, ot = load_prefs (Filename.concat dirname "pref.met") in
  let temp_dir = ref (Filename.concat dirname "temp") in

  List.iter (fun tag ->
      match tag with
      | { tag_name = "name"; tag_value = String s } ->
          client_name =:=  s
      | { tag_name = "port"; tag_value = Uint64 v } ->
          port =:=  Int64.to_int v
      | _ -> ()
  ) ct;

  List.iter (fun tag ->
      match tag with
      | { tag_name = "temp"; tag_value = String s } ->
          if Sys.file_exists s then (* be careful on that *)
            temp_dir := s
          else (Printf.printf "Bad temp directory, using default";
              print_newline ();)
      | _ -> ()
  ) ot;

  import_temp !temp_dir
  
let broadcast msg =
  let s = msg ^ "\n" in
  let len = String.length s in
  List.iter (fun sock ->
      TcpBufferedSocket.write sock s 0 len
  ) !user_socks

  (*
let saved_name file =
  let name = longest_name file in
(*  if !!use_mp3_tags then
    match file.file_format with
      Mp3 tags ->
        let module T = Mp3tag in
        let name = match name.[0] with
            '0' .. '9' -> name
          | _ -> Printf.sprintf "%02d-%s" tags.T.tracknum name
        in
        let name = if tags.T.album <> "" then
            Printf.sprintf "%s/%s" tags.T.album name
          else name in
        let name = if tags.T.artist <> "" then
            Printf.sprintf "%s/%s" tags.T.artist name
          else name in
        name          
    | _ -> name
else *)
  name
    *)

let print_file buf file =
  Printf.bprintf buf "[%-5d] %s %10Ld %32s %s" 
    (file_num file)
    (file_best_name file)
  (file_size file)
  (Md4.to_string file.file_md4)
  (if file_state file = FileDownloaded then
      "done" else
      Int64.to_string (file_downloaded file));
  Buffer.add_char buf '\n';
  Printf.bprintf buf "Connected clients:\n";
  let f _ c =
    match c.client_kind with
      Known_location (ip, port) ->
        Printf.bprintf  buf "[%-5d] %12s %-5d    %s\n"
          (client_num c)
          (Ip.to_string ip)
        port
          (match c.client_sock with
            None -> string_of_date (connection_last_conn
                  c.client_connection_control)
          | Some _ -> "Connected")
    | _ ->
        Printf.bprintf  buf "[%-5d] %12s            %s\n"
          (client_num c)
          "indirect"
          (match c.client_sock with
            None -> string_of_date (connection_last_conn
                  c.client_connection_control)
          | Some _ -> "Connected")
  in

  (* Intmap.iter f file.file_sources; *)
  Printf.bprintf buf "\nChunks: \n";
  Array.iteri (fun i c ->
      Buffer.add_char buf (
        match c with
          PresentVerified -> 'V'
        | PresentTemp -> 'p'
        | AbsentVerified -> '_'
        | AbsentTemp -> '.'
        | PartialTemp _ -> '?'
        | PartialVerified _ -> '!'
      )
  ) file.file_chunks

let recover_md4s md4 =
  let file = find_file md4 in  
  if file.file_chunks <> [||] then
    for i = 0 to file.file_nchunks - 1 do
      file.file_chunks.(i) <- (match file.file_chunks.(i) with
          PresentVerified -> PresentTemp
        | AbsentVerified -> AbsentTemp
        | PartialVerified x -> PartialTemp x
        | x -> x)
    done
    

    
let parse_donkey_url url =
  match String2.split (String.escaped url) '|' with
  | "ed2k://" :: "file" :: name :: size :: md4 :: _
  | "file" :: name :: size :: md4 :: _ ->
      query_download [name] (Int64.of_string size)
      (Md4.of_string md4) None None None false;
      true
  | "ed2k://" :: "server" :: ip :: port :: _
  | "server" :: ip :: port :: _ ->
      let ip = Ip.of_string ip in
      let s = add_server ip (int_of_string port) in
      server_connect (as_server s.server_server);
      true 
  | "ed2k://" :: "friend" :: ip :: port :: _
  | "friend" :: ip :: port :: _ ->
      let ip = Ip.of_string ip in
      let port = int_of_string port in
      let c = new_client (Known_location (ip,port)) in
      new_friend c;
      true

  | _ -> false

let commands = [
    "n", Arg_multiple (fun args o ->
        let buf = o.conn_buf in
        let ip, port =
          match args with
            [ip ; port] -> ip, port
          | [ip] -> ip, "4661"
          | _ -> failwith "n <ip> [<port>]: bad argument number"
        in
        let ip = Ip.of_string ip in
        let port = int_of_string port in
        
        let s = add_server ip port in
        Printf.bprintf buf "New server %s:%d\n" 
          (Ip.to_string ip) port;
        ""
    ), "<ip> [<port>] :\t\t\tadd a server";
    
    "vu", Arg_none (fun o ->
        let buf = o.conn_buf in
        Printf.sprintf "Upload credits : %d minutes\nUpload disabled for %d minutes" !upload_credit !has_upload;
    
    ), ":\t\t\t\t\tview upload credits";
    
    
    "comments", Arg_one (fun filename o ->
        let buf = o.conn_buf in
        DonkeyIndexer.load_comments filename;
        DonkeyIndexer.save_comments ();
        "comments loaded and saved"
    ), "<filename> :\t\t\tload comments from file";
    
    "comment", Arg_two (fun md4 comment o ->
        let buf = o.conn_buf in
        let md4 = Md4.of_string md4 in
        DonkeyIndexer.add_comment md4 comment;
        "Comment added"
    ), "<md4> \"<comment>\" :\t\tadd comment on an md4";
    
    "nu", Arg_one (fun num o ->
        let buf = o.conn_buf in
        let num = int_of_string num in
        
        if num > 0 then (* we want to disable upload for a short time *)
          let num = mini !upload_credit num in
          has_upload := !has_upload + num;
          upload_credit := !upload_credit - num;
          Printf.sprintf
            "upload disabled for %d minutes (remaining credits %d)" 
            !has_upload !upload_credit
        else
        
        if num < 0 && !has_upload > 0 then
(* we want to restart upload probably *)
          let num = - num in
          let num = mini num !has_upload in
          has_upload := !has_upload - num;
          upload_credit := !upload_credit + num;
          Printf.sprintf
            "upload disabled for %d minutes (remaining credits %d)" 
            !has_upload !upload_credit
        
        else ""
    ), "<m> :\t\t\t\tdisable upload during <m> minutes (multiple of 5)";
    
    "import", Arg_one (fun dirname o ->
        let buf = o.conn_buf in
        try
          import_config dirname;
          "config loaded"
        with e ->
            Printf.sprintf "error %s while loading config" (
              Printexc2.to_string e)
    ), "<dirname> :\t\t\timport the config from dirname";
    
    "import_temp", Arg_one (fun dirname o ->
        let buf = o.conn_buf in
        try
          import_temp dirname;
          "temp files loaded"
        with e ->
            Printf.sprintf "error %s while loading temp files" (
              Printexc2.to_string e)
    ), "<temp_dir> :\t\timport the old edonkey temp directory";
    
    "load_old_history", Arg_none (fun o ->
        let buf = o.conn_buf in
        DonkeyIndexer.load_old_history ();
        "Old history loaded"
    ), ":\t\t\tload history.dat file";
    
    "servers", Arg_one (fun filename o ->
        let buf = o.conn_buf in
        try
          let n = load_server_met filename in
          Printf.sprintf "%d servers loaded" n
        with e -> 
            Printf.sprintf "error %s while loading file" (Printexc2.to_string e)
    ), "<filename> :\t\t\tadd the servers from a server.met file";
    
    
    "id", Arg_none (fun o ->
        let buf = o.conn_buf in
        List.iter (fun s ->
            Printf.bprintf buf "For %s:%d  --->   %s\n"
              (Ip.to_string s.server_ip) s.server_port
              (if Ip.valid s.server_cid then
                Ip.to_string s.server_cid
              else
                Int64.to_string (Ip.to_int64 (Ip.rev s.server_cid)))
        ) (connected_servers());
        ""
    ), ":\t\t\t\t\tprint ID on connected servers";
    
    "bs", Arg_multiple (fun args o ->
        List.iter (fun arg ->
            let ip = Ip.of_string arg in
            server_black_list =:=  ip :: !!server_black_list;
        ) args;
        "done"
    ), "<ip1> <ip2> ... :\t\t\tadd these IPs to the servers black list";
    
    "port", Arg_one (fun arg o ->
        port =:= int_of_string arg;
        "new port will change at next restart"),
    "<port> :\t\t\t\tchange connection port";
    
    "add_url", Arg_two (fun kind url o ->
        let buf = o.conn_buf in
        let v = (kind, 1, url) in
        if not (List.mem v !!web_infos) then
          web_infos =:=  v :: !!web_infos;
        load_url kind url;
        "url added to web_infos. downloading now"
    ), "<kind> <url> :\t\t\tload this file from the web.
\t\t\t\t\tkind is either server.met (if the downloaded file is a server.met)";
    
    "scan_temp", Arg_none (fun o ->
        let buf = o.conn_buf in
        let list = Unix2.list_directory !!temp_directory in
        List.iter (fun filename ->
            try
              let md4 = Md4.of_string filename in
              try
                let file = find_file md4 in
                Printf.bprintf buf "%s is %s %s\n" filename
                  (file_best_name file)
                "(downloading)" 
              with _ ->
                  Printf.bprintf buf "%s %s %s\n"
                    filename
                    (if List.mem md4 !!old_files then
                      "is an old file" else "is unknown")
                  (try
                      let names = DonkeyIndexer.find_names md4 in
                      List.hd names
                    with _ -> "and never seen")
            
            with _ -> 
                Printf.bprintf buf "%s unknown\n" filename
        
        ) list;
        "done";
    ), ":\t\t\t\tprint temp directory content";
    
    "recover_temp", Arg_none (fun o ->
        let buf = o.conn_buf in
        let files = Unix2.list_directory !!temp_directory in
        List.iter (fun filename ->
            if String.length filename = 32 then
              try
                let md4 = Md4.of_string filename in
                try
                  ignore (Hashtbl.find files_by_md4 md4)
                with Not_found ->
                    let size = Unix32.getsize64 (Filename.concat 
                          !!temp_directory filename) in
                    let names = try DonkeyIndexer.find_names md4 
                      with _ -> [] in
                      query_download names size md4 None None None true;
                      recover_md4s md4
              with e ->
                  Printf.printf "exception %s in recover_temp"
                    (Printexc2.to_string e); print_newline ();
        ) files;
        "done"
    ), ":\t\t\t\trecover lost files from temp directory";

(*
    
    "upstats", Arg_none (fun o ->
        let buf = o.conn_buf in
        Printf.bprintf buf "Upload statistics:\n";
        Printf.bprintf buf "Total: %s bytes uploaded\n" 
          (Int64.to_string !upload_counter);
        let list = ref [] in
        Hashtbl.iter (fun _ file ->
            match file.file_shared with
              None -> ()
            | Some file ->
                list := file :: !list
        ) files_by_md4;
        let list = Sort.list (fun f1 f2 ->
              f1.impl_shared_requests >= f2.impl_shared_requests)
          !list in
        List.iter (fun impl ->
            Printf.bprintf buf "%-50s requests: %8d bytes: %10s\n"
              impl.impl_shared_codedname impl.impl_shared_requests
              (Int64.to_string impl.impl_shared_uploaded);
        ) list;
        "done"
    ), ":\t\t\tstatistics on upload";
*)
    
    "sources", Arg_none (fun o ->
        let buf = o.conn_buf in
        DonkeySources1.S.print_sources buf;
        "done"
    ), ":\t\t\t\tshow sources currently known";
    
    "update_sources", Arg_none (fun o ->
        let buf = o.conn_buf in
        DonkeySources1.S.recompute_ready_sources ();
        "done"
    ), ":\t\t\t\trecompute order of connections to sources(experimental)";
    
    "uploaders", Arg_none (fun o ->
        let buf = o.conn_buf in
        Fifo.iter (fun c ->
            client_print (as_client c.client_client) o;
            Printf.bprintf buf "client: %s downloaded: %s uploaded: %s" (brand_to_string c.client_brand) (Int64.to_string c.client_downloaded) (Int64.to_string c.client_uploaded);
            match c.client_upload with
              Some cu ->
                Printf.bprintf buf "\nfilename: %s\n\n" (file_best_name cu.up_file)
            | None -> ()
        ) upload_clients;
        Printf.sprintf "Total number of uploaders : %d" 
          (Fifo.length upload_clients);
    ), ":\t\t\t\tshow users currently uploading";
    
    
    "xs", Arg_none (fun o ->
        let buf = o.conn_buf in
        if !xs_last_search >= 0 then begin
            try
              make_xs (CommonSearch.search_find !xs_last_search);
              "extended search done"
            with e -> Printf.sprintf "Error %s" (Printexc2.to_string e)
          end else "No previous extended search"),
    ":\t\t\t\t\textended search";
    
    "clh", Arg_none (fun o ->
        let buf = o.conn_buf in
        DonkeyIndexer.clear ();
        "local history cleared"
    ), ":\t\t\t\t\tclear local history";
    
    "dllink", Arg_multiple (fun args o ->        
        let buf = o.conn_buf in
        let url = String2.unsplit args ' ' in
        if parse_donkey_url url then
          "download started"
        else "bad syntax"
    ), "<ed2klink> :\t\t\tdownload ed2k:// link";
    
    "dd", Arg_two(fun size md4 o ->
        let buf = o.conn_buf in
        query_download [] (Int64.of_string size)
        (Md4.of_string md4) None None None false;
        "download started"
    
    ), "<size> <md4> :\t\t\tdownload from size and md4";
    
    "remove_old_servers", Arg_none (fun o ->
        let buf = o.conn_buf in
        DonkeyServers.remove_old_servers ();
        "clean done"
    ), ":\t\t\tremove servers that have not been connected for several days";
    
    
    
    "bp", Arg_multiple (fun args o ->
        List.iter (fun arg ->
            let port = int_of_string arg in
            port_black_list =:=  port :: !!port_black_list;
        ) args;
        "done"
    ), "<port1> <port2> ... :\t\tadd these Ports to the port black list";

    "send_servers", Arg_none (fun o ->
        DonkeyProtoCom.propagate_working_servers 
          (List.map (fun s -> s.server_ip, s.server_port)
          (connected_servers()))
        (DonkeyOvernet.connected_peers ())
        ;
        "done"
    ), ":\t\t\t\tsend the list of connected servers to the redirector";
    
  ]
  
let _ =
  register_commands commands;
  file_ops.op_file_resume <- (fun file ->
      reconnect_all file;
  );
  file_ops.op_file_set_priority <- (fun file _ ->
      DonkeySources1.S.recompute_ready_sources ()     
  );
  file_ops.op_file_pause <- (fun file -> ()
  );
  file_ops.op_file_commit <- (fun file new_name ->
      if not (List.mem file.file_md4 !!old_files) then
        old_files =:= file.file_md4 :: !!old_files;
      DonkeyShare.remember_shared_info file new_name
  );
  network.op_network_connected <- (fun _ ->
    !nservers > 0  
  );
  network.op_network_private_message <- (fun iddest s ->      
      try
        let c = DonkeyGlobals.find_client_by_name iddest in
        match c.client_sock with
          None -> 
            (
(* A VOIR  : est-ce que c'est bien de fait comme �a ? *)
              DonkeyClient.reconnect_client c;
              match c.client_sock with
                None ->
                  CommonChat.send_text !!CommonOptions.chat_console_id None 
                    (Printf.sprintf "client %s : could not connect (client_sock=None)" iddest)
              | Some sock ->
                  direct_client_send sock (DonkeyProtoClient.SayReq s)
            )
        | Some sock ->
            direct_client_send sock (DonkeyProtoClient.SayReq s)
      with
        Not_found ->
          CommonChat.send_text !!CommonOptions.chat_console_id None 
            (Printf.sprintf "client %s unknown" iddest)
  )

let _ =
  result_ops.op_result_info <- (fun rs ->
      let r = Store.get store rs.result_index in
      r.result_num <- rs.result_result.impl_result_num;
      r
  )

module P = GuiTypes

let _ =
  file_ops.op_file_info <- (fun file ->
      try
        let v = 
          {
            P.file_name = file_best_name file;
            P.file_num = (file_num file);
            P.file_network = network.network_num;
            P.file_names = file.file_filenames;
            P.file_md4 = file.file_md4;
            P.file_size = file_size file;
            P.file_downloaded = file_downloaded file;
            P.file_nlocations = 0;
            P.file_nclients = 0;
            P.file_state = file_state file;
            P.file_sources = None;
            P.file_download_rate = file_download_rate file.file_file;
            P.file_chunks = (
              let nchunks = file.file_nchunks in
              let s = String.make file.file_nchunks '0' in
              if file.file_chunks <> [||] then begin
                  for i = 0 to nchunks - 1 do
                    match file.file_chunks.(i) with
                      PresentTemp | PresentVerified -> 
                        s.[i] <- '1'
                    | _ -> ()
                  done;
                end;
              s
              
            );          
            P.file_priority = file_priority  file;
            P.file_availability = String2.init file.file_nchunks (fun i ->
                let n = min file.file_available_chunks.(i) 255 in
                char_of_int n 
            );
            P.file_format = file.file_format;
            P.file_chunks_age = file.file_chunks_age;
            P.file_age = file_age file;
            P.file_last_seen = file.file_file.impl_file_last_seen;
          } in
        v
      with e ->
          Printf.printf "Exception %s in op_file_info" (Printexc2.to_string e);
          print_newline ();
          raise e
          
  )
  
let _ =
  server_ops.op_server_info <- (fun s ->
      {
        P.server_num = (server_num s);
        P.server_network = network.network_num;
        P.server_addr = new_addr_ip s.server_ip;
        P.server_port = s.server_port;
        P.server_score = s.server_score;
        P.server_tags = s.server_tags;
        P.server_nusers = s.server_nusers;
        P.server_nfiles = s.server_nfiles;
        P.server_state = server_state s;
        P.server_name = s.server_name;
        P.server_description = s.server_description;
        P.server_users = None;
      }
  )


let _ =
  user_ops.op_user_info <- (fun u ->
      {
        P.user_num = u.user_user.impl_user_num;
        P.user_md4 = u.user_md4;
        P.user_ip = u.user_ip;
        P.user_port = u.user_port;
        P.user_tags = u.user_tags;
        P.user_name = u.user_name;
        P.user_server = u.user_server.server_server.impl_server_num;
      }
  )

let _ =
  client_ops.op_client_info <- (fun c ->
      {
        P.client_network = network.network_num;
        P.client_kind = c.client_kind;
        P.client_state = client_state c;
        P.client_type = client_type c;
        P.client_tags = c.client_tags;
        P.client_name = c.client_name;
        P.client_files = None;
        P.client_num = (client_num c);
        P.client_rating = c.client_rating;
        P.client_chat_port = c.client_chat_port ;
      }
  )

  
  
let _ =
  result_ops.op_result_download <- result_download
  
let _ =
  network.op_network_connect_servers <- (fun _ ->
      force_check_server_connections true
  )
let disconnect_server s =
  match s.server_sock with
    None -> ()
  | Some sock ->
      TcpBufferedSocket.shutdown sock "user disconnect"
      
let _ =
  server_ops.op_server_remove <- (fun s ->
      DonkeyComplexOptions.remove_server s.server_ip s.server_port
  );
  server_ops.op_server_connect <- connect_server;
  server_ops.op_server_disconnect <- disconnect_server;

  server_ops.op_server_query_users <- (fun s ->
      match s.server_sock, server_state s with
        Some sock, (Connected _ | Connected_downloading) ->
          direct_server_send sock (DonkeyProtoServer.QueryUsersReq "");
          Fifo.put s.server_users_queries false
      | _ -> ()
  );
  server_ops.op_server_find_user <- (fun s user ->
      match s.server_sock, server_state s with
        Some sock, (Connected _ | Connected_downloading) ->
          direct_server_send sock (DonkeyProtoServer.QueryUsersReq user);
          Fifo.put s.server_users_queries true
      | _ -> ()      
  );
  server_ops.op_server_users <- (fun s ->
      List2.tail_map (fun u -> as_user u.user_user) s.server_users)    ;
  ()

let _ =
  file_ops.op_file_save_as <- (fun file name ->
      file.file_filenames <- [name];
      set_file_best_name (as_file file.file_file) name
  );
  file_ops.op_file_set_format <- (fun file format ->
      file.file_format <- format);
  file_ops.op_file_check <- (fun file ->
      DonkeyOneFile.verify_chunks file);  
  file_ops.op_file_recover <- (fun file ->
      if file_state file = FileDownloading then 
        reconnect_all file);  
  file_ops.op_file_sources <- (fun file ->
      let list = ref [] in
      Intmap.iter (fun _ c -> 
          list := (as_client c.client_client) :: !list) file.file_locations;
      !list
  );
  file_ops.op_file_cancel <- (fun file ->
      Hashtbl.remove files_by_md4 file.file_md4;
      current_files := List2.removeq file !current_files;
      (try  Sys.remove (file_disk_name file)  with e -> 
            Printf.printf "Sys.remove %s exception %s" 
            (file_disk_name file)
            (Printexc2.to_string e); print_newline ());
      if !!keep_cancelled_in_old_files &&
        not (List.mem file.file_md4 !!old_files) then
        old_files =:= file.file_md4 :: !!old_files;
  );
  file_ops.op_file_comment <- (fun file ->
      Printf.sprintf "ed2k://|file|%s|%Ld|%s|" 
        (file_best_name file)
      (file_size file)
      (Md4.to_string file.file_md4)
  )
  
let _ =
  network.op_network_extend_search <- (fun s e ->
      match e with
      | ExtendSearchLocally ->
          DonkeyIndexer.find s      
      | ExtendSearchRemotely ->
          make_xs s
  );
  
  network.op_network_clean_servers <- (fun _ ->
      DonkeyServers.remove_old_servers ());
  
  network.op_network_connect_servers <- (fun _ ->
      force_check_server_connections true);
  
  network.op_network_parse_url <- parse_donkey_url;
  
  network.op_network_forget_search <- forget_search

let _ =
  client_ops.op_client_say <- (fun c s ->
      match c.client_sock with
        None -> ()
      | Some sock ->
          direct_client_send sock (DonkeyProtoClient.SayReq s)
  );  
  client_ops.op_client_files <- (fun c ->
      match c.client_all_files with
        None ->  []
      | Some files -> 
          List2.tail_map (fun r -> "", as_result r.result_result) files);
  client_ops.op_client_browse <- (fun c immediate ->
(*      Printf.printf "should browse"; print_newline (); *)
      browse_client c 
  );
  client_ops.op_client_connect <- (fun c ->
      match c.client_sock with
        None ->  reconnect_client c
      | _ -> ()
  );
  client_ops.op_client_clear_files <- (fun c ->
      c.client_all_files <- None;
  );
  client_ops.op_client_bprint <- (fun buf c ->
      Printf.bprintf buf "\t\t%s (last_ok <%s> lasttry <%s> nexttry <%s> onlist %b)\n"
        c.client_name 
        (let last = c.client_connection_control.control_last_ok in
        if last < 1 then "never" else string_of_date last)
        (let last = c.client_connection_control.control_last_try in
        if last < 1 then "never" else string_of_date last)
      (string_of_date (connection_next_try c.client_connection_control))
      c.client_on_list
  )

let _ =
  user_ops.op_user_set_friend <- (fun u ->
      let s = u.user_server in
      add_user_friend s u
  )

  
let _ =
  shared_ops.op_shared_unshare <- (fun file ->
      match file.file_shared with
        None -> ()
      | Some s -> 
          file.file_shared <- None;
          decr nshared_files;
          (try Unix32.close  (file_fd file) with _ -> ());
          try Hashtbl.remove files_by_md4 file.file_md4 with _ -> ()
  );
  shared_ops.op_shared_info <- (fun file ->
   let module T = GuiTypes in
     match file.file_shared with
        None -> assert false
      | Some impl ->
          { (impl_shared_info impl) with 
            T.shared_network = network.network_num;
            T.shared_filename = file_best_name file;
            T.shared_id = file.file_md4;
            }
  );
  pre_shared_ops.op_shared_info <- (fun s ->
      let module T = GuiTypes in
      let impl = s.shared_shared in
      { (impl_shared_info impl) with 
        T.shared_network = network.network_num }
  )

let _ =
  add_web_kind "server.met" (fun filename ->
      Printf.printf "FILE LOADED"; print_newline ();
      let n = load_server_met filename in
      Printf.printf "%d SERVERS ADDED" n; print_newline ();    
  );
  add_web_kind "servers.met" (fun filename ->
      Printf.printf "FILE LOADED"; print_newline ();
      let n = load_server_met filename in
      Printf.printf "%d SERVERS ADDED" n; print_newline ();    
  );
  add_web_kind "comments.met" (fun filename ->
      DonkeyIndexer.load_comments filename;
      Printf.printf "COMMENTS ADDED"; print_newline ();   
  )
  