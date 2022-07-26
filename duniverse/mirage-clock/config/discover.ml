module C = Configurator.V1

let () =
  C.main ~name:"mirage-clock-unix" (fun c ->
      let is_android =
        let defines =
          C.C_define.import c ~includes:[] [ ("__ANDROID__", Switch) ]
        in
        match defines with (_, Switch true) :: _ -> true | _ -> false
      in
      let ccflags =
        match (C.ocaml_config_var c "system", is_android) with
        | Some "linux", false -> [ "-lrt" ]
        | _ -> []
      in
      C.Flags.write_sexp "cclib.sexp" ccflags)
