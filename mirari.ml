(* #!/usr/local/bin/ocaml *)

let conf_file, xen =
  let xen = ref false in
  let usage_msg = "Usage: ocaml mirari.ml <conf-file>" in
  let file = ref None in
  let anon_fun f = match !file with
    | None   -> file := Some f
    | Some _ ->
      Printf.eprintf "%s\n" usage_msg;
      exit 1 in
  let specs = Arg.align [
      "xen", Arg.Set xen, " Generate xen image."
    ] in
  Arg.parse specs anon_fun usage_msg;
  match !file with
  | None  ->
    Printf.eprintf "%s\n" usage_msg;
    exit 1
  | Some f -> f, !xen

let gen_main_sh = "gen_main.sh"
let gen_xen_sh = "gen_main.sh"
let build_sh = "build.sh"
let full_build_sh = Filename.concat (Filename.dirname conf_file) build_sh
let main_ml = Filename.concat (Filename.dirname conf_file) "main.ml"

let lines_of_file file =
  let ic = open_in file in
  let lines = ref [] in
  let rec aux () =
    let line =
      try Some (input_line ic)
      with _ -> None in
    match line with
    | None   -> ()
    | Some l ->
      lines := l :: !lines;
      aux () in
  aux ();
  close_in ic;
  List.rev !lines

let strip str =
  let p = ref 0 in
  let l = String.length str in
  let fn = function
    | ' ' | '\t' | '\r' | '\n' -> true
    | _ -> false in
  while !p < l && fn (String.unsafe_get str !p) do
    incr p;
  done;
  let p = !p in
  let l = ref (l - 1) in
  while !l >= p && fn (String.unsafe_get str !l) do
    decr l;
  done;
  String.sub str p (!l - p + 1)

let cut_at s sep =
  try
    let i = String.index s sep in
    let name = String.sub s 0 i in
    let version = String.sub s (i+1) (String.length s - i - 1) in
    Some (name, version)
  with _ ->
    None

let key_value line =
  match cut_at line ':' with
  | None       -> None
  | Some (k,v) -> Some (k, strip v)

let filter_map f l =
  let rec loop accu = function
    | []     -> List.rev accu
    | h :: t ->
        match f h with
        | None   -> loop accu t
        | Some x -> loop (x::accu) t in
  loop [] l

let subcommand ~prefix (command, value) =
  let p1 = String.uncapitalize prefix in
  match cut_at command '-' with
  | None      -> None
  | Some(p,n) ->
    let p2 = String.uncapitalize p in
    if p1 = p2 then
      Some (n, value)
    else
      None

let remove oc file =
  Printf.fprintf oc "rm %s\n" file

let echo oc ~file fmt =
  Printf.kprintf (fun str ->
    Printf.fprintf oc "echo '%s' >> %s\n" str file
  ) fmt

let gen_crunch_commands oc kvs =
  let kvs = filter_map (subcommand ~prefix:"fs") kvs in
  List.iter (fun (k,v) ->
    if Sys.file_exists v then
      Printf.fprintf oc "mir-crunch -name %S %s > filesystem_%s.ml\n" k v k
    else
      Printf.eprintf "The directory %s does not exist.\n" v
  ) kvs;
  let echo fmt = echo oc ~file:main_ml fmt in
  echo "(* Generated by mirari *)";
  echo "";
  List.iter (fun (k,_) ->
    echo "open Filesystem_%s" k
  ) kvs

let gen_network_commands oc kvs =
  let kvs = filter_map (subcommand ~prefix:"ip") kvs in
  let echo fmt = echo oc ~file:main_ml fmt in
  match kvs with
  | ["use-dhcp", "true"] -> echo "let ip = `DHCP"
  | _ ->
    let address =
      try List.assoc "address" kvs
      with _ -> "10.0.0.2" in
    let netmask =
      try List.assoc "netmask" kvs
      with _ -> "255.255.255.0" in
    let gateway =
      try List.assoc "gateway" kvs
      with _ -> "10.0.0.1" in
    echo "let get = function Some x -> x | None -> failwith \"Bad IP!\"";
    echo "let ip = `IPv4 (";
    echo "  get (Net.Nettypes.ipv4_addr_of_string %S)," address;
    echo "  get (Net.Nettypes.ipv4_addr_of_string %S)," netmask;
    echo "  [get (Net.Nettypes.ipv4_addr_of_string %S)]" gateway;
    echo ")"

let gen_listen_commands oc kvs =
  let kvs = filter_map (subcommand ~prefix:"listen") kvs in
  let echo fmt = echo oc ~file:main_ml fmt in
  let port =
    try List.assoc "port" kvs
    with _ -> "80" in
  echo "let listen_port = %s" port;
  try
    let a = List.assoc "address" kvs in
    echo "let listen_address = Net.Nettypes.ipv4_addr_of_string %S" a
  with _ ->
    echo "let listen_address = None"

let gen_header oc =
  Printf.fprintf oc "#!/bin/sh -e\n# Generated by mirari\n"

let gen_main oc kvs =
  let echo fmt = echo oc ~file:main_ml fmt in
  let http_main () =
    if List.mem_assoc "http-main" kvs then (
      let main = List.assoc "http-main" kvs in
      echo "let main () =";
      echo "  let spec = Cohttp_lwt_mirage.Server.({";
      echo "    callback    = %s;" main;
      echo "    conn_closed = (fun _ () -> ());";
      echo "  }) in";
      echo "  Net.Manager.create (fun mgr interface id ->";
      echo "    Printf.eprintf \"listening to HTTP on port %%d\\\\n\" listen_port;";
      echo "    Net.Manager.configure interface ip >>";
      echo "    Cohttp_lwt_mirage.listen mgr (listen_address, listen_port) spec";
      echo "  )"
    ) in
  let ip_main () =
    if List.mem_assoc "ip-main" kvs then (
      let main = List.assoc "ip-main" kvs in
      echo "let main () =";
      echo "  Net.Manager.create (fun mgr interface id ->";
      echo "    Net.Manager.configure interface ip >>";
      echo "    %s" main;
      echo "  )"
    ) in
  remove oc main_ml;
  ip_main ();
  http_main ();
  echo "";
  echo "let () = OS.Main.run (main ())"

let gen_xen_script oc =
  let echo fmt = echo oc ~file:gen_xen_sh fmt in
  remove oc gen_xen_sh;
  echo "#!/bin/sh";
  echo "TARGET=%s" main_ml;
  echo "if [ -e ./_build/${TARGET}.nobj.o ]; then";
  echo "  mir-build -b xen-native -o ./_build/${TARGET}.xen ./_build/${TARGET}.nobj.o";
  echo "fi"

let gen_build_script oc =
  let echo fmt = echo oc ~file:full_build_sh fmt in
  remove oc full_build_sh;
  echo "#!/bin/sh -e";
  echo "rm -rf _build setup.data";
  echo "ocaml setup.ml -configure %s"
    (if xen then "--enable-xen" else "--enable-unix");
  echo "ocaml setup.ml -build -j 8"

let run cmd =
    match Sys.command ("sh " ^ cmd) with
    | 0 -> ()
    | i -> exit i

let () =
  let lines = lines_of_file conf_file in
  let kvs = filter_map key_value lines in
  let oc = open_out gen_main_sh in

  Printf.printf "Generating %s.\n%!" gen_main_sh;
  gen_header oc;
  gen_crunch_commands oc kvs;
  echo oc "";
  gen_network_commands oc kvs;
  echo oc "";
  gen_listen_commands oc kvs;
  echo oc "";
  gen_main oc kvs;
  echo oc "";
  gen_build_script oc;
  if xen then gen_xen_script oc;
  close_out oc;

  run gen_main_sh;
  let pwd = Sys.getcwd () in
  Sys.chdir (Filename.dirname conf_file);
  run build_sh;
  if xen then run gen_xen_sh


