GenerateTsconfigInput = provider(
    fields = [
        "tsconfig_template_json_file",
        "srcs",
        "out_dir",
        "package_relative_path",
        "paths_mapping",
    ]
)

TscResult = provider(
    fields = [
        "ts_path",
        "tsc_out_dir",
        "ts_declaration_files",
    ]
)

CumulativeJsResult = provider(
    fields = [
        "ts_path_to_js_dir",
        "js_and_sourcemap_files",
    ]
)

def _impl(ctx):
    generate_tsconfig_json_js_script = ctx.attr._generate_tsconfig_json_js.files.to_list()[0]
    source_root_dir = ctx.label.package # might want to make this overridable in the future
    tsc_script = ctx.attr.tsc_script.files.to_list()[0]
    node_modules_path = tsc_script.path.split("/node_modules/")[0] + "/node_modules"
    tsconfig_json = ctx.attr.tsconfig_json.files.to_list()[0]
    node_executable = ctx.attr.node_executable.files.to_list()[0]

    ts_path = ctx.attr.ts_path
    if len(ts_path) == 0:
        ts_path = ctx.label.package.split("/")[-1]

    tsc_out_dir = None

    if len(ctx.attr.srcs) == 0:
        fail("tsc rule error: srcs must have at least one item.")

    tsc_outputs = []
    ts_declaration_outputs = []
    js_and_sourcemap_outputs = []

    src_file_paths = []
    src_files = []
    for src in ctx.attr.srcs:
        f = src.files.to_list()[0]
        src_file_paths.append(f.path.replace(source_root_dir + "/", "", 1))
        src_files.append(f)

        basename_without_extension = f.basename.rsplit("." + f.extension, 1)[0]
        declaration_out_file = ctx.actions.declare_file("%s.d.ts" % basename_without_extension)
        js_out_file = ctx.actions.declare_file("%s.js" % basename_without_extension)
        sourcemap_out_file = ctx.actions.declare_file("%s.js.map" % basename_without_extension)

        bazel_out_root_dir = declaration_out_file.dirname.split(ctx.label.package)[0]
        tsc_out_dir = bazel_out_root_dir + ctx.label.package

        ts_declaration_outputs.append(declaration_out_file)
        js_and_sourcemap_outputs.append(js_out_file)
        js_and_sourcemap_outputs.append(sourcemap_out_file)

        tsc_outputs.append(declaration_out_file)
        tsc_outputs.append(js_out_file)
        tsc_outputs.append(sourcemap_out_file)

    if tsc_out_dir == None:
        fail("tsc rule error: must be compile at least one file")

    cumulative_js_result = CumulativeJsResult(
        ts_path_to_js_dir = {},
        js_and_sourcemap_files = []
    )
    deps_files = []
    paths_mapping = {}
    dependency_ts_declaration_files = []
    for dep in ctx.attr.deps:
        for f in dep.files.to_list():
            deps_files.append(f)

        if TscResult in dep:
            r = dep[TscResult]
            next_ts_path = r.ts_path + "/*"
            if next_ts_path in paths_mapping:
                fail("tsc rule error: ts_path '%s' apparently defined twice" % r.ts_path)
            paths_mapping[r.ts_path + "/*"] = [r.tsc_out_dir + "/*"]
            dependency_ts_declaration_files.extend(r.ts_declaration_files.to_list())

        if CumulativeJsResult in dep:
            r = dep[CumulativeJsResult]

            if r.ts_path_to_js_dir != None:
                for p in r.ts_path_to_js_dir:
                    cumulative_js_result.ts_path_to_js_dir[p] = r.ts_path_to_js_dir[p]

            cumulative_js_result.js_and_sourcemap_files.extend(r.js_and_sourcemap_files)

    script_input_data_file = ctx.actions.declare_file("generate_tsconfig_input.json")
    ctx.actions.write(
        output=script_input_data_file,
        content=GenerateTsconfigInput(
            tsconfig_template_json_file=tsconfig_json.path,
            srcs=src_file_paths,
            out_dir=tsc_out_dir,
            package_relative_path=ctx.label.package,
            paths_mapping=paths_mapping,
        ).to_json())

    generated_tsconfig_json_file = ctx.actions.declare_file("tsconfig.gen-initial.json")

    ts_inputs = src_files + dependency_ts_declaration_files

    ctx.action(
        command="%s %s %s > %s" % (
            node_executable.path,
            generate_tsconfig_json_js_script.path,
            script_input_data_file.path,
            generated_tsconfig_json_file.path
        ),
        inputs=ts_inputs,
        outputs = [generated_tsconfig_json_file],
        progress_message = "generating tsconfig for '%s'..." % ts_path,
        tools = [
            node_executable,
            generate_tsconfig_json_js_script,
            tsconfig_json,
            script_input_data_file,
        ]
    )

    # You would think that with moduleResolution=node in tsconfig, that something like NODE_PATH
    # would be scanned my tsc. That's not the case, per
    # https://www.typescriptlang.org/docs/handbook/module-resolution.html
    # Instead it insists on this parent-directory-walking strategy. Sigh.
    # also relevant, and disapointing https://github.com/Microsoft/TypeScript/issues/8760
    #
    # So the strategy below is to just symlink to the node_modules sitting under external/ ,
    # in a tsc-friendly location.

    ctx.action(
        command=" && ".join([
            "cp %s tsconfig.for-use.json" % generated_tsconfig_json_file.path,
            "ln -sf %s node_modules" % node_modules_path,
            "%s %s -p tsconfig.for-use.json" % (
                node_executable.path,
                tsc_script.path
            ),
        ]),
        inputs=[generated_tsconfig_json_file] + ts_inputs,
        outputs = tsc_outputs,
        progress_message = "running tsc for '%s'..." % ts_path,
        tools = [
            node_executable,
            tsc_script,
        ] + deps_files
    )

    # The "additional" file is here so the action cache invalidates
    # when anything that is returned by this rule changes, or is important
    # re: the tsc run.
    additional_file = ctx.actions.declare_file("additional_output_for_hashing")
    ctx.actions.write(
        output=additional_file,
        content="\n".join([
            ts_path,
            tsc_out_dir,
            node_executable.path,
            tsc_script.path,
        ]))

    ts_path_to_js_dir = cumulative_js_result.ts_path_to_js_dir
    if ts_path in ts_path_to_js_dir:
        fail("tsc rule error: ts_path '%s' apparently defined twice" % r.ts_path)
    ts_path_to_js_dir[ts_path] = tsc_out_dir

    return [
        DefaultInfo(
            files=depset(
                [additional_file, generated_tsconfig_json_file] +
                ts_declaration_outputs +
                dependency_ts_declaration_files
            ),
        ),
        TscResult(
            ts_path=ts_path,
            tsc_out_dir=tsc_out_dir,
            ts_declaration_files=depset(ts_declaration_outputs), # note: dependency .d.ts's not propagated
        ),
        CumulativeJsResult(
            ts_path_to_js_dir=ts_path_to_js_dir,
            js_and_sourcemap_files=cumulative_js_result.js_and_sourcemap_files + js_and_sourcemap_outputs,
        )
    ]

tsc = rule(
    implementation = _impl,

    attrs = {
      "ts_path": attr.string(),
      "srcs": attr.label_list(allow_files=True, mandatory=True),
      "deps": attr.label_list(default=[]),

      "node_executable": attr.label(allow_files=True, mandatory=True),
      "tsc_script": attr.label(allow_files=True, mandatory=True),
      "tsconfig_json": attr.label(allow_files=True, mandatory=True),

      "_generate_tsconfig_json_js": attr.label(default=Label("//private:generate_tsconfig_json.js"), allow_files=True, single_file=True),
    }
)