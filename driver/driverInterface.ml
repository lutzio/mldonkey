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

open UdpSocket
open CommonShared
open CommonEvent
open CommonRoom
open CommonTypes
open CommonComplexOptions
open CommonUser
open CommonSearch
open CommonNetwork
open CommonResult
open GuiTypes
open GuiProto
open CommonTypes
open CommonFile
open CommonClient
open CommonServer
open Options
open BasicSocket
open TcpBufferedSocket
open CommonOptions
open CommonGlobals
  
module P = GuiProto
  
let gui_send gui t =
  match gui.gui_sock with
    None -> 
      Fifo.put core_gui_fifo t
  | Some sock ->
      try
        GuiEncoding.gui_send (GuiEncoding.to_gui gui.gui_version) 
        sock t
      with UnsupportedGuiMessage -> 
(* the message is probably not supported by this GUI *)
          ()

let gui_can_write gui =
  match gui.gui_sock with
    None -> not !gui_reconnected
  | Some sock -> TcpBufferedSocket.can_write sock
          
let restart_gui_server = ref (fun _ -> ())

let update_events gui update user_num map =
  if not gui.gui_poll then
    let gui_num = gui.gui_num in
    if update = 0 then
      addevent map user_num true
    else
    if update > 0 then
      (if update < gui_num then
          addevent map user_num true)
    else
      (if - update < gui_num then
          addevent map user_num true
        else
          addevent map user_num false)      
  
let update_user_info user =
  let impl = as_user_impl user in
  let update = impl.impl_user_update in
  let user_num = impl.impl_user_num in
  if update < !gui_counter then begin
      with_guis (fun gui -> 
          update_events gui update user_num (gui.gui_users)
      );
      impl.impl_user_update <- !gui_counter
    end
  
let update_client_info client =
  let impl = as_client_impl client in
  let update = impl.impl_client_update in
  let client_num = impl.impl_client_num in
  if update < !gui_counter then begin
      with_guis (fun gui -> 
          update_events gui update client_num (gui.gui_clients)
      );
      impl.impl_client_update <- !gui_counter
    end
  
let update_server_info server =
  let impl = as_server_impl server in
  let update = impl.impl_server_update in
  let server_num = impl.impl_server_num in
  if update < !gui_counter then begin
      with_guis (fun gui -> 
          update_events gui update server_num ( gui.gui_servers)
      );
      impl.impl_server_update <- !gui_counter
    end
  
let update_file_info file =
  let impl = as_file_impl file in
  let update = impl.impl_file_update in
  let file_num = impl.impl_file_num in
  if update < !gui_counter then begin
      with_guis (fun gui -> 
          update_events gui update file_num (gui.gui_files)
      );
      impl.impl_file_update <- !gui_counter
    end
  
let update_room_info room =
  let impl = as_room_impl room in
  let update = impl.impl_room_update in
  let room_num = impl.impl_room_num in
  if update < !gui_counter then begin
      with_guis (fun gui -> 
          update_events gui update room_num (gui.gui_rooms)
      );
      impl.impl_room_update <- !gui_counter
    end
  
let update_result_info result =
  let impl = as_result_impl result in
  let update = impl.impl_result_update in
  let result_num = impl.impl_result_num in
  if update < !gui_counter then begin
      with_guis (fun gui -> 
          update_events gui update result_num ( gui.gui_results)
      );
      impl.impl_result_update <- !gui_counter
    end
  
let update_shared_info shared =
  let impl = as_shared_impl shared in
  let update = impl.impl_shared_update in
  let shared_num = impl.impl_shared_num in
  if update < !gui_counter then begin
      with_guis (fun gui -> 
          update_events gui update shared_num ( gui.gui_shared_files)
      );
      impl.impl_shared_update <- !gui_counter
    end

  
let catch m f =
  try f () with e ->
      Printf.printf "Exception %s for message %s" (Printexc2.to_string e) m;
      print_newline () 

let send_event gui ev = 
  match ev with
  | Room_add_user_event (room, user) ->
      gui_send gui (P.Room_add_user (room_num room, user_num user)) 
      
  | Room_remove_user_event (room, user) ->
      gui_send gui (P.Room_remove_user (room_num room, user_num user))
      
  | Room_message_event (_, room, msg) ->            
      gui_send gui (P.Room_message (room_num room, msg))
      
  | Client_new_file_event (c, dirname, r) ->
      gui_send gui (P.Client_file (client_num c, dirname, 
                    result_num r) )

  | File_add_source_event (f,c) ->
      gui_send gui (P.File_add_source (file_num f, client_num c));      

  | File_update_availability (f,c,avail) ->
      gui_send gui (P.File_update_availability (file_num f, client_num c,avail));      
      
  | File_remove_source_event (f,c) ->
      gui_send gui (P.File_remove_source (file_num f, client_num c));      
      
  | Server_new_user_event (s,u) ->
      gui_send gui (P.Server_user (server_num s, user_num u))
      
  | Search_new_result_event (for_gui, int, r) ->      
      gui_send gui (P.Search_result (int, result_num r))
    
  | Console_message_event msg ->
      gui_send gui (P.Console msg)

  | _ ->  Printf.printf "Event not treated"; print_newline ()
    
let send_update_file gui file_num update =
  let file = file_find file_num in
  let impl = as_file_impl file in
  let file_info = if update then
      P.File_info (file_info file) 
    else
      P.File_downloaded (impl.impl_file_num,
        impl.impl_file_downloaded,
        file_download_rate impl,
        impl.impl_file_last_seen)
  in
  gui_send gui file_info

let send_update_user gui user_num update =
  let user = user_find user_num in
  let user_info = P.User_info (user_info user) in
  gui_send gui user_info
  
let send_update_client gui client_num update =
  let client = client_find client_num in
  let impl = as_client_impl client in
  let client_info = if update then
      P.Client_info (client_info client) 
    else
      P.Client_state (
        impl.impl_client_num, 
        impl.impl_client_state) 
  in
  gui_send gui client_info
  
let send_update_server gui server_num update =
  let server = server_find server_num in
  let impl = as_server_impl server in
  let server_info = if update then
      P.Server_info (server_info server) 
    else
      P.Server_state (impl.impl_server_num, impl.impl_server_state)
  in
  gui_send gui server_info

let send_update_room gui room_num update =
  let room = room_find room_num in
  let room_info = P.Room_info (room_info room) in
  gui_send gui room_info

let send_update_result gui result_num update =
  let result = result_find result_num in
  let impl = as_result_impl result in
  let result_info = P.Result_info (result_info result) in
  gui_send gui result_info  
  
  let send_update_shared gui shfile_num update =
    let shared = CommonShared.shared_find shfile_num in
    let impl = as_shared_impl shared in
    let msg = if update then
        P.Shared_file_info (shared_info shared)
      else
        P.Shared_file_upload (
          impl.impl_shared_num,
          impl.impl_shared_uploaded, 
          impl.impl_shared_requests)
    in
    gui_send gui msg

let send_update_old gui =
  match gui.gui_old_events with
  | ev :: tail ->
      gui.gui_old_events <- tail;
      send_event gui ev;
      true
  | [] ->
      match gui.gui_new_events with
        [] -> false
      | list ->
          gui.gui_old_events <- List.rev list;
          gui.gui_new_events <- [];
          true
          
let connecting_writer gui _ =
  try
    
    let rec iter list =
      if gui_can_write gui then
        match list with
          [] -> if send_update_old gui then iter []
        |  (events, f) :: tail ->
            match events.num_list with
              [] -> iter tail
            | num :: tail ->
                events.num_list <- tail;
                let update = Intmap.find num events.num_map in
                events.num_map <- Intmap.remove num events.num_map ;
                (try f gui num update with _ -> ());
                iter list
    in
    iter [
        (gui.gui_files, send_update_file);
        (gui.gui_users, send_update_user);
        (gui.gui_clients, send_update_client);
        (gui.gui_servers, send_update_server);
        (gui.gui_rooms, send_update_room);
        (gui.gui_results, send_update_result);
        (gui.gui_shared_files, send_update_shared);      
      ]

                    
          
          (*
      getevents  gui
        [
        
        (gui.gui_files, send_update_file);
        
        (gui.gui_users, send_update_user);
        
        (gui.gui_clients, send_update_client);
        
        (gui.gui_servers, send_update_server);
        
        (gui.gui_rooms, send_update_room);
        
        (gui.gui_results, send_update_result);
        
        (gui.gui_shared_files, send_update_shared);
      
      ]
send_update_old        
  *)
  with _ -> ()

let console_messages = Fifo.create ()
        
let gui_closed gui sock  msg =
(*  Printf.printf "DISCONNECTED FROM GUI"; print_newline (); *)
  guis := List2.removeq gui !guis

let gui_reader (gui: gui_record) t _ =
    
  let module P = GuiProto in  
  try
    match t with    
    
    | GuiProtocol version ->
        gui.gui_version <- min GuiEncoding.best_gui_version version;
        Printf.printf "Using protocol %d for communications with the GUI" 
          gui.gui_version;
        print_newline ();
    
    | P.GuiExtensions list ->
        List.iter (fun (ext, bool) ->
            if ext = P.gui_extension_poll then
              (            
                Printf.printf "Extension POLL %b" bool; print_newline ();
                gui.gui_poll <- bool
              )
        ) list
    
    | P.Password s ->
        begin
          match gui.gui_sock with
            Some sock when s <> !!password ->
              gui_send gui BadPassword;                  
              set_lifetime sock 5.;
              Printf.printf "BAD PASSWORD"; print_newline ();
              TcpBufferedSocket.close sock "bad password"
          
          | _ ->
              let connecting = ref true in

(*
            begin
              match !gui_option with
                None -> ()
              | Some gui -> close gui.gui_sock "new gui"
end;
  *)
              guis := gui :: !guis;
              
              
              gui.gui_auth <- true;
              
              if gui.gui_poll then begin
                  
                  gui.gui_new_events <- [];
                  gui.gui_old_events <- [];
                  
                  gui.gui_files <- create_events ();            
                  gui.gui_clients <- create_events ();
                  gui.gui_servers <- create_events ();
                  gui.gui_rooms <- create_events ();
                  gui.gui_users <- create_events ();
                  gui.gui_results <- create_events ();
                  gui.gui_shared_files <- create_events ();
                
                
                end else begin
                  
                  List.iter (fun c ->
                      addevent gui.gui_clients (client_num c) true
                  ) !!friends;
                  
                  List.iter (fun file ->
                      addevent gui.gui_files (file_num file) true;
                      List.iter (fun c ->
                          addevent gui.gui_clients (client_num c) true;
                          gui.gui_new_events <-
                            (File_add_source_event (file,c))
                          :: gui.gui_new_events
                      ) (file_sources file)
                  ) !!files;
                  
                  List.iter (fun file ->
                      addevent gui.gui_files (file_num file) true;
                  ) !!done_files;
                  
                  networks_iter (fun n ->
                      List.iter (fun s ->
                          addevent gui.gui_servers (server_num s) true
                      ) (n.op_network_connected_servers ())
                  );
                  
                  server_iter (fun s ->
                      addevent gui.gui_servers (server_num s) true
                  );
                  
                  rooms_iter (fun room ->
                      if room_state room <> RoomClosed then begin
                          addevent gui.gui_rooms (room_num room) true;
                          List.iter (fun user ->
                              Printf.printf "room add user"; print_newline ();
                              addevent gui.gui_users (user_num user) true;
                              gui.gui_new_events <-
                                (Room_add_user_event (room,user))
                              :: gui.gui_new_events
                          ) (room_users room)
                        
                        end
                  );
                  
                  shared_iter (fun s ->
                      addevent gui.gui_shared_files (shared_num s) true
                  );
                  
                  Fifo.iter (fun ev ->
                      gui.gui_new_events <- ev :: gui.gui_new_events
                  ) console_messages;                
                  
                  gui_send gui (
                    P.Options_info (simple_options downloads_ini));
                  networks_iter_all (fun r ->
                      match r.network_config_file with
                        None -> ()
                      | Some opfile ->
(*
Printf.printf "options for net %s" r.network_name; print_newline ();
*)
                          let args = simple_options opfile in
                          let prefix = r.network_prefix in
(*
Printf.printf "Sending for %s" prefix; print_newline ();
 *)
                          gui_send gui (P.Options_info (
                              List.map (fun (arg, value) ->
                                  let long_name = Printf.sprintf "%s%s" !!prefix arg in
                                  (long_name, value)
                              )  args)
                          );
(*                            Printf.printf "sent for %s" prefix; print_newline (); *)
                  
                  );

(* Options panels defined in downloads.ini *)
                  List.iter (fun (section, message, option, optype) ->
                      gui_send gui (
                        P.Add_section_option (section, message, option,
                          match optype with
                          | "B" -> BoolEntry 
                          | "F" -> FileEntry 
                          | _ -> StringEntry
                        )))
                  !! gui_options_panel;

(* Options panels defined in each plugin *)
                  List.iter (fun (section, list) ->
                      
                      List.iter (fun (message, option, optype) ->
                          gui_send gui (
                            P.Add_plugin_option (section, message, option,
                              match optype with
                              | "B" -> BoolEntry 
                              | "F" -> FileEntry 
                              | _ -> StringEntry
                            )))
                      !!list)
                  ! CommonInteractive.gui_options_panels;
                  
                  gui_send gui (P.DefineSearches !!CommonComplexOptions.customized_queries);
                  match gui.gui_sock with
                    None -> ()
                  | Some sock ->
                      BasicSocket.must_write (TcpBufferedSocket.sock sock) true;
                      set_handler sock WRITE_DONE (connecting_writer gui);
                end
        end
    | _ ->
        if gui.gui_auth then
          match t with
          | P.Command cmd ->
              let buf = Buffer.create 1000 in
              Buffer.add_string buf "\n----------------------------------\n";
              Printf.bprintf buf "Eval command: %s\n\n" cmd;
              let options = { conn_output = TEXT; conn_sortvd = BySize;
                  conn_filter = (fun _ -> ()); conn_buf = buf;
                } in
              DriverControlers.eval (ref true) cmd options;
              Buffer.add_string buf "\n\n";
              gui_send gui (P.Console (Buffer.contents buf))
          
          | P.SetOption (name, value) ->
              CommonInteractive.set_fully_qualified_options name value
          
          | P.ForgetSearch num ->
              let s = List.assoc num gui.gui_searches in
              search_forget s
          
          | P.SendMessage (num, msg) ->
              begin
                try
                  let room = room_find num in
                  room_send_message room msg
                with _ ->
                    match msg with (* no room ... maybe a private message *)
                      PrivateMessage (num, s) -> 
                        client_say (client_find num) s
                    | _ -> assert false
              end
          
          | P.EnableNetwork (num, bool) ->
              let n = network_find_by_num num in
              if n.op_network_is_enabled () <> bool then
                (try
                    if bool then network_enable n else network_disable n;
                  with e ->
                      Printf.printf "Exception %s in network enable/disable" 
                        (Printexc2.to_string e);
                      print_newline ());
              gui_send gui (P.Network_info (network_info n))
          
          | P.ExtendedSearch (num, e) ->
              let s = 
                if num = -1 then
                  match !searches with
                    [] -> raise Not_found
                  | s :: _ -> s
                else
                  List.assoc num gui.gui_searches in
              networks_iter (fun r -> network_extend_search r s e)
          
          | P.KillServer -> 
              exit_properly 0
          
          | P.Search_query s ->
              let query = 
                try CommonGlobals.simplify_query
                    (CommonSearch.mftp_query_of_query_entry 
                      s.GuiTypes.search_query)
                with Not_found ->
                    prerr_endline "Not_found in mftp_query_of_query_entry";
                    raise Not_found
              in
              let buf = Buffer.create 100 in
              let num = s.GuiTypes.search_num in
              let search = CommonSearch.new_search 
                  { s with GuiTypes.search_query = query} in
              gui.gui_search_nums <- num ::  gui.gui_search_nums;
              gui.gui_searches <- (num, search) :: gui.gui_searches;
              search.op_search_new_result_handlers <- (fun r ->
                  CommonEvent.add_event
                    (Search_new_result_event (gui, num, r))
              ) :: search.op_search_new_result_handlers;
              networks_iter (fun r -> r.op_network_search search buf);

(*
        search.op_search_end_reply_handlers <- 
          (fun _ -> send_waiting gui num search.search_waiting) ::
search.op_search_end_reply_handlers;
  *)
          
          | P.Download_query (filenames, num, force) ->
              begin
                let r = result_find num in
                result_download r filenames force
              end
          
          | P.ConnectMore_query ->
              networks_iter network_connect_servers
          
          | P.Url url ->
              ignore (networks_iter_until_true (fun n -> network_parse_url n url))
          
          | P.RemoveServer_query num ->
              server_remove (server_find num)
          
          | P.SaveOptions_query list ->
              
              List.iter (fun (name, value) ->
                  CommonInteractive.set_fully_qualified_options name value) list;
              DriverInteractive.save_config ()
          
          | P.RemoveDownload_query num ->
              file_cancel (file_find num)
          
          | P.ServerUsers_query num -> 
              let s = server_find num in
              server_query_users s
          
          | P.SetFilePriority (num, prio) ->
              let file = file_find num in
              file_set_priority file prio
              
          | P.SaveFile (num, name) ->
              let file = file_find num in
              set_file_best_name file name;
              (match file_state file with
                  FileDownloaded ->
                    file_save_as file name;
                    file_commit file
                | _ -> ())
          
          | P.Preview num ->
              begin
                let file = file_find num in
                let cmd = Printf.sprintf "%s \"%s\" \"%s\"" !!previewer
                    (file_disk_name file) (file_best_name file) in
                ignore (Sys.command cmd)
              end
          
          | P.AddClientFriend num ->
              let c = client_find num in
              friend_add c
          
          | P.BrowseUser num ->
              let user = user_find num in
              user_browse_files user
          
          | P.GetClient_files num ->        
              let c = client_find num in
(*        Printf.printf "GetClient_files %d" num; print_newline (); *)
              List.iter (fun (dirname, r) ->
(* delay sending to update *)
                  client_new_file c dirname r
              ) (client_files c)
          
          | P.GetClient_info num ->
              addevent gui.gui_clients num true
          
          | P.GetUser_info num ->
              addevent gui.gui_users num true
          
          | P.GetServer_users num ->    
              let s = server_find num in
              let users = server_users s in
              List.iter (fun user ->
                  server_new_user s user
              ) users
          
          | P.GetServer_info num ->
              addevent gui.gui_servers num true
          
          | P.GetFile_locations num ->
              let file = file_find num in
              let clients = file_sources file in
              List.iter (fun c ->
                  file_add_source file c
              ) clients
          
          | P.GetFile_info num ->
              addevent gui.gui_files num true
          
          | P.ConnectFriend num ->
              let c = client_find num in
              client_connect c
          
          | P.ConnectServer num -> 
              server_connect (server_find num)
          
          | P.DisconnectServer num -> 
              server_disconnect (server_find num)
          
          | P.ConnectAll num -> 
              let file = file_find num in
              file_recover file        
          
          | P.QueryFormat num ->
              begin
                try
                  let file = file_find num in
                  let filename = file_disk_name file in
                  let format = CommonMultimedia.get_info filename in
                  file_set_format file format;
                  file_must_update file;
                with _ -> ()
              end
          
          | P.ModifyMp3Tags (num, tag) ->
              begin
                try 
                  let file = file_find num in
                  let filename = file_disk_name file in
                  Mp3tag.Id3v1.write tag filename;
                with 
                  _ -> ()
              end
          
          | P.SwitchDownload (num, resume) ->
              let file = file_find num in
              if resume then
                file_resume file          
              else
                file_pause file
          
          | P.ViewUsers num -> 
              let s = server_find num in
              server_query_users s
          
          | P.FindFriend user -> 
              networks_iter (fun n ->
                  List.iter (fun s -> server_find_user s user) 
                  (network_connected_servers n))
          
          | P.RemoveFriend num -> 
              let c = client_find num in
              friend_remove c 
          
          | P.RemoveAllFriends ->
              List.iter (fun c ->
                  friend_remove c
              ) !!friends
          
          | P.CleanOldServers -> 
              networks_iter network_clean_servers
          
          | P.AddUserFriend num ->
              let user = user_find num in
              user_set_friend user
          
          | P.VerifyAllChunks num ->
              let file = file_find num in
              file_check file 
          
          | P.Password _ | P.GuiProtocol _ | P.GuiExtensions _ -> 
(* These messages are handled before, since they can be received without
  authentication *)
              assert false

(* version 3 *)
          
          | P.MessageToClient (num, mes) ->
              Printf.printf "MessageToClient(%d,%s)" num mes;
              print_newline ();
              let c = client_find num in
              client_say c mes
          
          | P.GetConnectedServers ->
              let list = ref [] in
              networks_iter (fun n ->
                  list := network_connected_servers n @ !list);
              gui_send gui (P.ConnectedServers (List2.tail_map
                    server_info !list))
          
          | P.GetDownloadedFiles ->
              gui_send gui (P.DownloadedFiles
                  (List2.tail_map file_info !!done_files))
          
          | P.GetDownloadFiles -> 
              gui_send gui (P.DownloadFiles
                  (List2.tail_map file_info !!files))              
          
          | SetRoomState (num, state) ->
              if num > 0 then begin
                  let room = room_find num in
                  match state with
                    RoomOpened -> room_resume room
                  | RoomClosed -> room_close room
                  | RoomPaused -> room_pause room
                end
          
          | RefreshUploadStats ->
              
              shared_iter (fun s ->
                  update_shared_info s;
              ) 
  
  with 
    Failure s ->
      gui_send gui (Console (Printf.sprintf "Failure: %s\n" s))
  | e ->
      gui_send gui (Console (    
          Printf.sprintf "from_gui: exception %s for message %s\n" (
            Printexc2.to_string e) (GuiProto.from_gui_to_string t)))

let new_gui sock =
  incr gui_counter;
  let gui = {
      gui_searches = [];
      gui_sock = sock;
      gui_search_nums = [];
      
      gui_new_events = [];
      gui_old_events = [];
      
      gui_files = create_events ();            
      gui_clients = create_events ();
      gui_servers = create_events ();
      gui_rooms = create_events ();
      gui_users = create_events ();
      gui_results = create_events ();
      gui_shared_files = create_events ();
      gui_version = 0;
      gui_num = !gui_counter;
      gui_auth = false;
      gui_poll = false;
    } in
  gui_send gui (P.CoreProtocol GuiEncoding.best_gui_version);
  networks_iter_all (fun n ->
      gui_send gui (Network_info (network_info n)));
  gui_send gui (Console (DriverControlers.text_of_html !!motd_html));
  gui
  
let gui_handler t event = 
  match event with
    TcpServerSocket.CONNECTION (s, Unix.ADDR_INET (from_ip, from_port)) ->
      let from_ip = Ip.of_inet_addr from_ip in
      Printf.printf "CONNECTION FROM GUI"; print_newline ();
      if Ip.matches from_ip !!allowed_ips then 
        
        let module P = GuiProto in
        let sock = TcpBufferedSocket.create_simple 
            "gui connection"
            s in
        
        let gui = new_gui (Some sock) in
        
        TcpBufferedSocket.set_max_write_buffer sock !!interface_buffer;
        TcpBufferedSocket.set_reader sock (GuiDecoding.gui_cut_messages
            (fun opcode s ->
              let m = GuiDecoding.from_gui opcode s in
              gui_reader gui m sock));
        TcpBufferedSocket.set_closer sock (gui_closed gui);
        TcpBufferedSocket.set_handler sock TcpBufferedSocket.BUFFER_OVERFLOW
          (fun _ -> 
            Printf.printf "BUFFER OVERFLOW"; print_newline ();
            close sock "overflow");
        (* sort GUIs in increasing order of their num *)
        
      else 
        Unix.close s
  | _ -> ()

let add_gui_event ev =
  with_guis (fun gui ->
      gui.gui_new_events <- ev :: gui.gui_new_events
  )

let rec update_events list = 
  match list with
    [] -> ()
  | event :: tail ->
      (try
          match event with
            Room_info_event room -> 
              update_room_info room
              
          | Room_add_user_event (room, user) ->
              update_room_info room;
              update_user_info user;
              add_gui_event event
          
          | Room_remove_user_event (room, user) ->
              update_room_info room;
              update_user_info user;
              add_gui_event event

          | Room_message_event (_, room, msg) ->            
              update_room_info room;
              begin
                match msg with
                  ServerMessage _ -> ()
                | PrivateMessage (user_num, _) 
                | PublicMessage (user_num, _) ->
                    try
                      let user = user_find user_num  in
                      update_user_info user
                    with _ ->
                        Printf.printf "USER NOT FOUND FOR MESSAGE"; 
                        print_newline ();
              end;
              add_gui_event event
              
          | Shared_info_event sh ->
              update_shared_info sh
              
          | Result_info_event r ->
              update_result_info r
              
          | Client_info_event c ->
              update_client_info c
              
          | Server_info_event s ->
              update_server_info s
              
          | File_info_event f ->
              update_file_info f
              
          | User_info_event u ->
              update_user_info u

          | Client_new_file_event (c,_,r) ->
              update_client_info c;
              update_result_info r;
              add_gui_event event
              
          | File_add_source_event (f,c)
          | File_update_availability (f,c,_) ->
              update_file_info f;
              update_client_info c;
              add_gui_event event
              
          | File_remove_source_event (f,c) ->
              update_file_info f;
              add_gui_event event
              
          | Server_new_user_event (s,u) ->
              update_server_info s;
              update_user_info u;
              add_gui_event event

          | Search_new_result_event (gui, int, r) ->
              update_result_info r;
              gui.gui_new_events <- event :: gui.gui_new_events
              
          | Console_message_event msg ->  
              Fifo.put console_messages event;
              if Fifo.length console_messages > 30 then begin
                  ignore (Fifo.take console_messages)
                end;
              add_gui_event event
              
        with _ -> ());
      update_events tail
      
let rec last = function
    [x] -> x
  | _ :: l -> last l
  | _ -> (last_time (), 0.0, 0.0)
    
let trimto list =
  let (list, _) = List2.cut 20 list in
  list 
  
let tcp_bandwidth_samples = ref []
let control_bandwidth_samples = ref []
let udp_bandwidth_samples = ref []

let compute_bandwidth uploaded_bytes downloaded_bytes bandwidth_samples =

  let time = last_time () in
  let last_count_time, last_uploaded_bytes, last_downloaded_bytes = 
    last !bandwidth_samples in
  
  let delay = float_of_int (time - last_count_time) in

  let uploaded_bytes = Int64.to_float uploaded_bytes in
  let downloaded_bytes = Int64.to_float downloaded_bytes in
  
  let upload_rate = if delay > 0. then
      int_of_float ( (uploaded_bytes -. last_uploaded_bytes) /. 
        delay )
    else 0 in
  
  let download_rate = if delay > 0. then
      int_of_float ( (downloaded_bytes -. last_downloaded_bytes) /. delay )
    else 0 in

  bandwidth_samples := trimto (
    (time, uploaded_bytes, downloaded_bytes) :: !bandwidth_samples);

  upload_rate, download_rate
  
(* We should probably only send "update" to the current state of
the info already sent to *)
let update_gui_info () =
  
  let tcp_upload_rate, tcp_download_rate = 
    compute_bandwidth !tcp_uploaded_bytes !tcp_downloaded_bytes
      tcp_bandwidth_samples in

  let control_upload_rate, control_download_rate = 
    compute_bandwidth (moved_bytes upload_control) 
    (moved_bytes download_control) 
      control_bandwidth_samples in
(*
  Printf.printf "BANDWIDTH %d/%d %d/%d" control_upload_rate tcp_upload_rate
    control_download_rate tcp_download_rate ;
  print_newline ();
*)
  
  let udp_upload_rate, udp_download_rate = 
    compute_bandwidth !udp_uploaded_bytes !udp_downloaded_bytes 
      udp_bandwidth_samples in
  
  let nets = ref [] in
  networks_iter (fun n -> if network_connected n then 
        nets := n.network_num :: !nets);
  
  let msg = (Client_stats {
        upload_counter = !upload_counter;
        download_counter = !download_counter;
        shared_counter = !shared_counter;
        nshared_files = !nshared_files;
        tcp_upload_rate = control_upload_rate;
        tcp_download_rate = control_download_rate;
        udp_upload_rate = udp_upload_rate;
        udp_download_rate = udp_download_rate;
        connected_networks = !nets;
        ndownloaded_files = List.length !!done_files;
        ndownloading_files = List.length !!files;
      }) in
  with_guis(fun gui -> 
      gui_send gui msg);       
  let events = List.rev !events_list in
  events_list := [];
  update_events events;
  with_guis (fun gui ->
      connecting_writer gui gui.gui_sock
  )
  
let install_hooks () = 
  List.iter (fun (name,_) ->
      set_option_hook downloads_ini name (fun _ ->
          with_guis (fun gui ->
              gui_send gui (P.Options_info [name, 
                  get_simple_option downloads_ini name])
          )
      )
  ) (simple_options downloads_ini)
  ;
  networks_iter_all (fun r ->
      match r.network_config_file with
        None -> ()
      | Some opfile ->
          let args = simple_options opfile in
          let prefix = r.network_prefix in
          List.iter (fun (arg, value) ->
              let long_name = Printf.sprintf "%s%s" !!prefix arg in
              set_option_hook opfile arg (fun _ ->
                  with_guis (fun gui ->
                      gui_send gui (P.Options_info [long_name, 
                          get_simple_option opfile arg])
                  )
              )                  
          )  args)
  ;
  
  private_room_ops.op_room_send_message <- (fun s msg ->
      match msg with
        PrivateMessage (c, s) ->
          with_guis (fun gui -> gui_send gui 
                (P.MessageFromClient (c, s)))
      
      | _ -> assert false
  )

let local_gui = ref None
  
let _ =
  add_init_hook (fun _ ->
      if !gui_included then
        add_infinite_timer 0.1 (fun _ ->
            begin
              match !local_gui with
                None -> ()
              | Some gui ->
                  if !gui_reconnected then begin
                      Printf.printf "close gui ..."; print_newline ();
                      local_gui := None;
                      gui_closed gui () ()
                    end else
                    (try
                        while true do
                          let m = Fifo.take gui_core_fifo in
                          gui_reader gui m ()
                        done
                      with Fifo.Empty -> ()
                      | e ->
                          Printf.printf "Exception %s in handle gui message"
                            (Printexc2.to_string e); 
                          print_newline ();)
            end;
            if !gui_reconnected then begin
                Printf.printf "gui_reconnected !"; print_newline ();
                gui_reconnected := false;
                let gui = new_gui None in
                local_gui := Some gui;
                ()
              end
        )
  )
  