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

open Printf2
open Md4
open Options

open BasicSocket
open TcpBufferedSocket
  
open CommonFile
open CommonShared
open CommonTypes
open CommonOptions
open CommonUploads
open CommonGlobals
open CommonSwarming.Int64Swarmer
  
open DonkeyMftp
open DonkeyImport
open DonkeyProtoCom
open DonkeyTypes
open DonkeyOptions
open DonkeyComplexOptions
open DonkeyGlobals

  
let md4_of_list md4s =
  let len = List.length md4s in
  let s = String.create (len * 16) in
  let rec iter list i =
    match list with
      [] -> ()
    | md4 :: tail ->
        let md4 = Md4.direct_to_string md4 in
        String.blit md4 0 s i 16;
        iter tail (i+16)
  in
  iter md4s 0;
  Md4.string s  

  
let tag_shared_file name sh =
  (string_tag "filename" name) ::
  (int32_tag "size" sh.shared_size) ::
  (
    (*
    (match sh.shared_format with
        FormatNotComputed next_time when
        next_time < last_time () ->
          (try
              if !verbose then begin
                  lprintf "%s: FIND FORMAT %s\n"
                    (string_of_date (last_time ()))
                  (sh.shared_fullname); 
                end;
              sh.shared_format <- (
                match
                  CommonMultimedia.get_info sh.shared_fullname
                with
                  FormatUnknown -> FormatNotComputed (last_time () + 300)
                | x -> x)
            with _ -> ())
      | _ -> ()
    );
*)
    
    match sh.shared_format with
      FormatNotComputed _ | FormatUnknown -> []
    | AVI _ ->
        [
          { tag_name = "type"; tag_value = String "Video" };
          { tag_name = "format"; tag_value = String "avi" };
        ]
    | MP3 _ ->
        [
          { tag_name = "type"; tag_value = String "Audio" };
          { tag_name = "format"; tag_value = String "mp3" };
        ]
    | FormatType (format, kind) ->
        [
          { tag_name = "type"; tag_value = String kind };
          { tag_name = "format"; tag_value = String format };
        ]
  )        
  
let all_tagged_files = ref []
let browsable_tagged_files = ref []
  
let update_shared_files () =
  if !new_shared_files then begin
      lprintf "update_shared_files\n";
      all_tagged_files := [];
      browsable_tagged_files := [];
      new_shared_files := false;

(* The list of complete files *)
      Hashtbl.iter (fun ed2k sh ->
          lprintf "shared ed2k files...\n";
          let name = Filename.basename sh.shared_codedname in
          let name, browsable = if String2.starts_with name "hidden." then
              String.sub name 7 (String.length name - 7), false
            else name, true in
          
          let f = 
            { f_md4 = ed2k;
              f_ip = client_ip None;
              f_port = !client_port;
              f_tags = tag_shared_file name sh;
            }
          in
          all_tagged_files := f :: !all_tagged_files;
          if browsable then
            browsable_tagged_files := f :: !browsable_tagged_files
      ) shared_by_md4;

(* The list of incomplete files *)
      Hashtbl.iter (fun ed2k file ->
          try
          if file.file_partially_shared || (
              let bitmap = verified_bitmap file.file_partition in
              try 
                let index = String.index bitmap '3' in
                file.file_partially_shared <- true;
                true
              with _ -> false) then 
            let f = 
              { f_md4 = ed2k;
                f_ip = client_ip None;
                f_port = !client_port;
                f_tags = [
                  (string_tag "filename" (file_best_name file));
                  (int32_tag "size" (file_size file));
                  (string_tag "downloading" "true")
                ]
                ;
              }
            in
            all_tagged_files := f :: !all_tagged_files;
            browsable_tagged_files := f :: !browsable_tagged_files
          with _ -> ()      
      ) files_by_md4;
    end
    
let all_shared () = 
  update_shared_files ();
  List.iter (fun f ->
      lprintf "SHARED FILE %s\n" (Md4.to_string f.f_md4);
  ) !all_tagged_files;
  !all_tagged_files 
  
let browsable_shared () =
  update_shared_files ();
  !browsable_tagged_files
  
  
(*  Check whether new files are shared, and send them to connected servers.
Do it only once per 5 minutes to prevent sending to many times all files.
  Should I only do it for master servers, no ?
*)
let old_shared = ref []
let send_new_shared () =
  if !all_tagged_files != !old_shared then
    begin
      old_shared := !all_tagged_files;
      List.iter (fun s ->
          if s.server_master then
            match s.server_sock with
              None -> ()
            | Some sock ->
                direct_server_send_share sock !all_tagged_files) 
      (connected_servers ());
    end

  
  (*[BROKEN]
let must_share_file file codedname has_old_impl =
  match file.file_shared with
  | Some _ -> ()
  | None ->
      new_shared := file :: !new_shared;
      let impl = {
          impl_shared_update = 1;
          impl_shared_fullname = file_disk_name file;
          impl_shared_codedname = codedname;
          impl_shared_size = file_size file;
          impl_shared_id = file.file_md4;
          impl_shared_num = 0;
          impl_shared_uploaded = Int64.zero;
          impl_shared_ops = shared_ops;
          impl_shared_val = file;
          impl_shared_requests = 0;
        } in
      file.file_shared <- Some impl;
      incr CommonGlobals.nshared_files;
      match has_old_impl with
        None -> update_shared_num impl
      | Some old_impl -> replace_shared old_impl impl

  
let new_file_to_share sh codedname old_impl =
  try
(* How do we compute the total MD4 of the file ? *)
    
    let md4s = sh.sh_md4s in
    let md4 = match md4s with
        [md4] -> md4
      | [] -> lprintf "No md4 for %s\n" sh.sh_name;
          raise Not_found
      | _ -> md4_of_list md4s
    in
    
    lprintf "Sharing file with MD4: %s\n" (Md4.to_string md4);
    
    let file = new_file FileShared sh.sh_name md4 sh.sh_size false in
    must_share_file file codedname old_impl;
    file.file_md4s <- Array.of_list md4s;
    file_md4s_to_register := file :: !file_md4s_to_register;
    let sh_name = Filename.basename sh.sh_name in
    if not (List.mem sh_name file.file_filenames) then begin
        file.file_filenames <- file.file_filenames @ [sh_name];
        update_best_name file;
      end;
    (*
    file.file_chunks <- Array.make file.file_nchunks PresentVerified;
file.file_absent_chunks <- [];
  *)
    (try 
        file.file_format <- CommonMultimedia.get_info 
          (file_disk_name file)
      with _ -> ());
    (*
    (try 
        DonkeyOvernet.publish_file file
      with e -> 
          lprintf "DonkeyOvernet.publish_file: %s\n" (Printexc2.to_string e);
);
  *)
    lprintf "Sharing %s\n" sh.sh_name;
  with e ->
      lprintf "Exception %s while sharing %s\n" (Printexc2.to_string e)
      sh.sh_name
      
  
let all_shared () =  
  let shared_files = ref [] in
  Hashtbl.iter (fun md4 file ->
      match  file.file_shared with
        None -> ()
      | Some _ ->  shared_files := file :: !shared_files
  ) files_by_md4;
  !shared_files

(*  Check whether new files are shared, and send them to connected servers.
Do it only once per 5 minutes to prevent sending to many times all files.
  Should I only do it for master servers, no ?
  *)
let send_new_shared () =
  if !new_shared != [] then
    begin
      new_shared := [];
      let socks = ref [] in
      let list = all_shared () in
      List.iter (fun s ->
          if s.server_master then
            match s.server_sock with
              None -> ()
            | Some sock ->
                direct_server_send_share sock list) (connected_servers ());
    end
          
(*
The problem: sh.shared_fd might be closed during the execution of the
thread. Moreover, we don't want to open all the filedescs for all the
files being shared !
*)

let computation = ref false
(*   Compute (at most) one MD4 chunk if needed. *)
let check_shared_files () =  
  let module M = CommonHasher in
  if not !computation then
    match !shared_files with
      [] -> ()  
    | sh :: files ->
        shared_files := files;

(*      lprintf "check_shared_files\n";  *)
        
        let rec job_creater _ =
          try
            if not (Sys.file_exists sh.shared_name) then begin
                lprintf "Shared file doesn't exist\n"; 
                raise Not_found;
              end;
            if Unix32.getsize64 sh.shared_name <> sh.shared_size then begin
                lprintf "Bad shared file size\n" ; 
                raise Not_found;
              end;
            let end_pos = Int64.add sh.shared_pos block_size in
            let end_pos = if end_pos > sh.shared_size then sh.shared_size
              else end_pos in
            let len = Int64.sub end_pos sh.shared_pos in
(*          lprintf "compute next md4\n";  *)
            
            computation := true;
            M.compute_md4 (Unix32.filename sh.shared_fd) sh.shared_pos len
              (fun job ->
                computation := false;
                if job.M.job_error then begin
                    lprintf "Error prevent sharing %s\n" sh.shared_name
                  end else 
                let _ = () in
(*              lprintf "md4 computed\n"; *)
                let new_md4 = Md4.direct_of_string job.M.job_result in
                
                sh.shared_list <- new_md4 :: sh.shared_list;
                sh.shared_pos <- end_pos;
                if end_pos = sh.shared_size then begin
                    let mtime = Unix32.mtime64 sh.shared_name  in
                    sh.shared_list <- List.rev sh.shared_list;
                    let s = CommonUploads.M.new_shared_info sh.shared_name sh.shared_size 
                        sh.shared_list mtime [] in
                    new_file_to_share s sh.shared_shared.impl_shared_codedname (Some  sh.shared_shared);
                    shared_remove  sh.shared_shared;
                  end
                else
                  job_creater ())
          with e ->
              lprintf "Exception %s prevents sharing\n"
                (Printexc2.to_string e);
        in
        job_creater ()
        
let local_dirname = Sys.getcwd ()
  
let _ =
  network.op_network_share <- (fun fullname codedname size ->
      if !verbose_share then begin
          lprintf "FULLNAME %s\n" fullname; 
        end;
(*      let codedname = Filename.basename codedname in*)
      if !verbose_share then begin
          lprintf "CODEDNAME %s\n" codedname; 
        end;
      try
(*
lprintf "Searching %s\n" fullname; 
*)
        let s = CommonUploads.M.find_shared_info fullname size in
        new_file_to_share s codedname None

      with Not_found ->
          if !verbose_share then begin
              lprintf "No info on %s\n" fullname; 
            end;
          
          let rec iter list left =
            match list with
              [] -> List.rev left
            | sh :: tail ->
                if sh.shared_name = fullname then iter tail left
                else iter tail (sh :: left)
          in
          shared_files := iter !shared_files [];
          
          let rec impl = {
              impl_shared_update = 1;
              impl_shared_fullname = fullname;
              impl_shared_codedname = codedname;
              impl_shared_size = size;
              impl_shared_num = 0;
              impl_shared_uploaded = Int64.zero;
              impl_shared_ops = pre_shared_ops;
          	  impl_shared_id = Md4.null;
              impl_shared_val = pre_shared;
              impl_shared_requests = 0;
            } and
            pre_shared = {
              shared_shared = impl;
              shared_name = fullname;              
              shared_size = size;
              shared_list = [];
              shared_pos = Int64.zero;
              shared_fd = Unix32.create fullname [Unix.O_RDONLY] 0o444;
            } in
          update_shared_num impl;  
          shared_files := pre_shared :: !shared_files;
  )
  
let remember_shared_info file new_name =
  if file.file_md4s <> [||] then
    try
      let disk_name = file_disk_name file in
      let mtime = Unix32.mtime64 disk_name in
      
      if !verbose_share then begin
          lprintf "Remember %s\n" new_name; 
        end;
      let s =
        CommonUploads.M.put_shared_info 
        new_name (file_size file) 
        (Array.to_list file.file_md4s) mtime []
      in
      ()
    with e ->
        lprintf "Exception %s in remember_shared_info\n"
          (Printexc2.to_string e)
        
let must_share_file file = must_share_file file (file_best_name file) None
  
*)