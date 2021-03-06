-module(rebar_prv_compile).

-behaviour(provider).

-export([init/1,
         do/1,
         format_error/1]).

-export([compile/2,
         compile/3]).

-include_lib("providers/include/providers.hrl").
-include("rebar.hrl").

-define(PROVIDER, compile).
-define(ERLC_HOOK, erlc_compile).
-define(APP_HOOK, app_compile).
-define(DEPS, [lock]).

%% ===================================================================
%% Public API
%% ===================================================================

-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    State1 = rebar_state:add_provider(State, providers:create([{name, ?PROVIDER},
                                                               {module, ?MODULE},
                                                               {bare, true},
                                                               {deps, ?DEPS},
                                                               {example, "rebar3 compile"},
                                                               {short_desc, "Compile apps .app.src and .erl files."},
                                                               {desc, "Compile apps .app.src and .erl files."},
                                                               {opts, [{deps_only, $d, "deps_only", undefined,
                                                                        "Only compile dependencies, no project apps will be built."}]}])),
    {ok, State1}.

-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()}.
do(State) ->
    IsDepsOnly = is_deps_only(State),
    rebar_paths:set_paths([deps], State),

    Providers = rebar_state:providers(State),
    Deps = rebar_state:deps_to_build(State),
    copy_and_build_apps(State, Providers, Deps),

    State1 = case IsDepsOnly of
                 true ->
                     State;
                 false ->
                     handle_project_apps(Providers, State)
             end,

    rebar_paths:set_paths([plugins], State1),

    {ok, State1}.

is_deps_only(State) ->
    {Args, _} = rebar_state:command_parsed_args(State),
    proplists:get_value(deps_only, Args, false).

handle_project_apps(Providers, State) ->
    Cwd = rebar_state:dir(State),
    ProjectApps = rebar_state:project_apps(State),
    {ok, ProjectApps1} = rebar_digraph:compile_order(ProjectApps),

    %% Run top level hooks *before* project apps compiled but *after* deps are
    rebar_hooks:run_all_hooks(Cwd, pre, ?PROVIDER, Providers, State),

    ProjectApps2 = copy_and_build_project_apps(State, Providers, ProjectApps1),
    State2 = rebar_state:project_apps(State, ProjectApps2),

    %% projects with structures like /apps/foo,/apps/bar,/test
    build_extra_dirs(State, ProjectApps2),

    State3 = update_code_paths(State2, ProjectApps2),

    rebar_hooks:run_all_hooks(Cwd, post, ?PROVIDER, Providers, State2),
    case rebar_state:has_all_artifacts(State3) of
        {false, File} ->
            throw(?PRV_ERROR({missing_artifact, File}));
        true ->
            true
    end,

    State3.


-spec format_error(any()) -> iolist().
format_error({missing_artifact, File}) ->
    io_lib:format("Missing artifact ~ts", [File]);
format_error({bad_project_builder, Name, Type, Module}) ->
    io_lib:format("Error building application ~s:~n     Required project builder ~s function "
                  "~s:build/1 not found", [Name, Type, Module]);
format_error({unknown_project_type, Name, Type}) ->
    io_lib:format("Error building application ~s:~n     "
                  "No project builder is configured for type ~s", [Name, Type]);
format_error(Reason) ->
    io_lib:format("~p", [Reason]).

copy_and_build_apps(State, Providers, Apps) ->
    [build_app(State, Providers, AppInfo) || AppInfo <- Apps].

build_app(State, Providers, AppInfo) ->
    AppDir = rebar_app_info:dir(AppInfo),
    OutDir = rebar_app_info:out_dir(AppInfo),
    copy_app_dirs(AppInfo, AppDir, OutDir),
    compile(State, Providers, AppInfo).

copy_and_build_project_apps(State, Providers, Apps) ->
    %% Top-level apps, because of profile usage and specific orderings (i.e.
    %% may require an include file from a profile-specific app for an extra_dirs
    %% entry that only exists in a test context), need to be
    %% copied and added to the path at once, and not just in compile order.
    [copy_app_dirs(AppInfo,
                   rebar_app_info:dir(AppInfo),
                   rebar_app_info:out_dir(AppInfo))
     || AppInfo <- Apps],
    code:add_pathsa([rebar_app_info:ebin_dir(AppInfo) || AppInfo <- Apps]),
    [compile(State, Providers, AppInfo) || AppInfo <- Apps].


build_extra_dirs(State, Apps) ->
    BaseDir = rebar_state:dir(State),
    F = fun(App) -> rebar_app_info:dir(App) == BaseDir end,
    %% check that this app hasn't already been dealt with
    case lists:any(F, Apps) of
        false ->
            ProjOpts = rebar_state:opts(State),
            Extras = rebar_dir:extra_src_dirs(ProjOpts, []),
            [build_extra_dir(State, Dir) || Dir <- Extras];
        true  -> ok
    end.

build_extra_dir(_State, []) -> ok;
build_extra_dir(State, Dir) ->
    case ec_file:is_dir(filename:join([rebar_state:dir(State), Dir])) of
        true ->
            BaseDir = filename:join([rebar_dir:base_dir(State), "extras"]),
            OutDir = filename:join([BaseDir, Dir]),
            rebar_file_utils:ensure_dir(OutDir),
            copy(rebar_state:dir(State), BaseDir, Dir),

            Compilers = rebar_state:compilers(State),
            FakeApp = rebar_app_info:new(),
            FakeApp1 = rebar_app_info:out_dir(FakeApp, BaseDir),
            FakeApp2 = rebar_app_info:ebin_dir(FakeApp1, OutDir),
            Opts = rebar_state:opts(State),
            FakeApp3 = rebar_app_info:opts(FakeApp2, Opts),
            FakeApp4 = rebar_app_info:set(FakeApp3, src_dirs, [OutDir]),
            rebar_compiler:compile_all(Compilers, FakeApp4);
        false ->
            ok
    end.

compile(State, AppInfo) ->
    compile(State, rebar_state:providers(State), AppInfo).

compile(State, Providers, AppInfo) ->
    ?INFO("Compiling ~ts", [rebar_app_info:name(AppInfo)]),
    AppDir = rebar_app_info:dir(AppInfo),
    AppInfo1 = rebar_hooks:run_all_hooks(AppDir, pre, ?PROVIDER,  Providers, AppInfo, State),

    AppInfo2 = rebar_hooks:run_all_hooks(AppDir, pre, ?ERLC_HOOK, Providers, AppInfo1, State),

    build_app(AppInfo2, State),

    AppInfo3 = rebar_hooks:run_all_hooks(AppDir, post, ?ERLC_HOOK, Providers, AppInfo2, State),

    AppInfo4 = rebar_hooks:run_all_hooks(AppDir, pre, ?APP_HOOK, Providers, AppInfo3, State),

    %% Load plugins back for make_vsn calls in custom resources.
    %% The rebar_otp_app compilation step is safe regarding the
    %% overall path management, so we can just load all plugins back
    %% in memory.
    rebar_paths:set_paths([plugins], State),
    AppFileCompileResult = rebar_otp_app:compile(State, AppInfo4),
    %% Clean up after ourselves, leave things as they were with deps first
    rebar_paths:set_paths([deps], State),

    case AppFileCompileResult of
        {ok, AppInfo5} ->
            AppInfo6 = rebar_hooks:run_all_hooks(AppDir, post, ?APP_HOOK, Providers, AppInfo5, State),
            AppInfo7 = rebar_hooks:run_all_hooks(AppDir, post, ?PROVIDER, Providers, AppInfo6, State),
            has_all_artifacts(AppInfo5),
            AppInfo7;
        Error ->
            throw(Error)
    end.

%% ===================================================================
%% Internal functions
%% ===================================================================

build_app(AppInfo, State) ->
    case rebar_app_info:project_type(AppInfo) of
        Type when Type =:= rebar3 ; Type =:= undefined ->
            Compilers = rebar_state:compilers(State),
            rebar_compiler:compile_all(Compilers, AppInfo);
        Type ->
            ProjectBuilders = rebar_state:project_builders(State),
            case lists:keyfind(Type, 1, ProjectBuilders) of
                {_, Module} ->
                    %% load plugins since thats where project builders would be
                    rebar_paths:set_paths([plugins, deps], State),
                    Res = Module:build(AppInfo),
                    rebar_paths:set_paths([deps], State),
                    case Res of
                        ok -> ok;
                        {error, Reason} -> throw({error, {Module, Reason}})
                    end;
                _ ->
                    throw(?PRV_ERROR({unknown_project_type, rebar_app_info:name(AppInfo), Type}))
            end
    end.

update_code_paths(State, ProjectApps) ->
    ProjAppsPaths = paths_for_apps(ProjectApps),
    ExtrasPaths = paths_for_extras(State, ProjectApps),
    DepsPaths = rebar_state:code_paths(State, all_deps),
    rebar_state:code_paths(State, all_deps, DepsPaths ++ ProjAppsPaths ++ ExtrasPaths).

paths_for_apps(Apps) -> paths_for_apps(Apps, []).

paths_for_apps([], Acc) -> Acc;
paths_for_apps([App|Rest], Acc) ->
    {_SrcDirs, ExtraDirs} = resolve_src_dirs(rebar_app_info:opts(App)),
    Paths = [filename:join([rebar_app_info:out_dir(App), Dir]) || Dir <- ["ebin"|ExtraDirs]],
    FilteredPaths = lists:filter(fun ec_file:is_dir/1, Paths),
    paths_for_apps(Rest, Acc ++ FilteredPaths).

paths_for_extras(State, Apps) ->
    F = fun(App) -> rebar_app_info:dir(App) == rebar_state:dir(State) end,
    %% check that this app hasn't already been dealt with
    case lists:any(F, Apps) of
        false -> paths_for_extras(State);
        true  -> []
    end.

paths_for_extras(State) ->
    {_SrcDirs, ExtraDirs} = resolve_src_dirs(rebar_state:opts(State)),
    Paths = [filename:join([rebar_dir:base_dir(State), "extras", Dir]) || Dir <- ExtraDirs],
    lists:filter(fun ec_file:is_dir/1, Paths).

has_all_artifacts(AppInfo1) ->
    case rebar_app_info:has_all_artifacts(AppInfo1) of
        {false, File} ->
            throw(?PRV_ERROR({missing_artifact, File}));
        true ->
            true
    end.

copy_app_dirs(AppInfo, OldAppDir, AppDir) ->
    case rebar_utils:to_binary(filename:absname(OldAppDir)) =/=
        rebar_utils:to_binary(filename:absname(AppDir)) of
        true ->
            EbinDir = filename:join([OldAppDir, "ebin"]),
            %% copy all files from ebin if it exists
            case filelib:is_dir(EbinDir) of
                true ->
                    OutEbin = filename:join([AppDir, "ebin"]),
                    filelib:ensure_dir(filename:join([OutEbin, "dummy.beam"])),
                    rebar_file_utils:cp_r(filelib:wildcard(filename:join([EbinDir, "*"])), OutEbin);
                false ->
                    ok
            end,

            filelib:ensure_dir(filename:join([AppDir, "dummy"])),

            %% link or copy mibs if it exists
            case filelib:is_dir(filename:join([OldAppDir, "mibs"])) of
                true ->
                    %% If mibs exist it means we must ensure priv exists.
                    %% mibs files are compiled to priv/mibs/
                    filelib:ensure_dir(filename:join([OldAppDir, "priv", "dummy"])),
                    symlink_or_copy(OldAppDir, AppDir, "mibs");
                false ->
                    ok
            end,
            {SrcDirs, ExtraDirs} = resolve_src_dirs(rebar_app_info:opts(AppInfo)),
            %% link to src_dirs to be adjacent to ebin is needed for R15 use of cover/xref
            %% priv/ and include/ are symlinked unconditionally to allow hooks
            %% to write to them _after_ compilation has taken place when the
            %% initial directory did not, and still work
            [symlink_or_copy(OldAppDir, AppDir, Dir) || Dir <- ["priv", "include"]],
            [symlink_or_copy_existing(OldAppDir, AppDir, Dir) || Dir <- SrcDirs],
            %% copy all extra_src_dirs as they build into themselves and linking means they
            %% are shared across profiles
            [copy(OldAppDir, AppDir, Dir) || Dir <- ExtraDirs];
        false ->
            ok
    end.

symlink_or_copy(OldAppDir, AppDir, Dir) ->
    Source = filename:join([OldAppDir, Dir]),
    Target = filename:join([AppDir, Dir]),
    rebar_file_utils:symlink_or_copy(Source, Target).

symlink_or_copy_existing(OldAppDir, AppDir, Dir) ->
    Source = filename:join([OldAppDir, Dir]),
    Target = filename:join([AppDir, Dir]),
    case ec_file:is_dir(Source) of
        true -> rebar_file_utils:symlink_or_copy(Source, Target);
        false -> ok
    end.

copy(OldAppDir, AppDir, Dir) ->
    Source = filename:join([OldAppDir, Dir]),
    Target = filename:join([AppDir, Dir]),
    case ec_file:is_dir(Source) of
        true  -> copy(Source, Target);
        false -> ok
    end.

%% TODO: use ec_file:copy/2 to do this, it preserves timestamps and
%% may prevent recompilation of files in extra dirs
copy(Source, Source) ->
    %% allow users to specify a directory in _build as a directory
    %% containing additional source/tests
    ok;
copy(Source, Target) ->
    %% important to do this so no files are copied onto themselves
    %% which truncates them to zero length on some platforms
    ok = delete_if_symlink(Target),
    ok = filelib:ensure_dir(filename:join([Target, "dummy.beam"])),
    {ok, Files} = rebar_utils:list_dir(Source),
    case [filename:join([Source, F]) || F <- Files] of
        []    -> ok;
        Paths -> rebar_file_utils:cp_r(Paths, Target)
    end.

delete_if_symlink(Path) ->
    case ec_file:is_symlink(Path) of
        true  -> file:delete(Path);
        false -> ok
    end.

resolve_src_dirs(Opts) ->
    SrcDirs = rebar_dir:src_dirs(Opts, ["src"]),
    ExtraDirs = rebar_dir:extra_src_dirs(Opts, []),
    normalize_src_dirs(SrcDirs, ExtraDirs).

%% remove duplicates and make sure no directories that exist
%% in src_dirs also exist in extra_src_dirs
normalize_src_dirs(SrcDirs, ExtraDirs) ->
    S = lists:usort(SrcDirs),
    E = lists:subtract(lists:usort(ExtraDirs), S),
    ok = warn_on_problematic_directories(S ++ E),
    {S, E}.

%% warn when directories called `eunit' and `ct' are added to compile dirs
warn_on_problematic_directories(AllDirs) ->
    F = fun(Dir) ->
        case is_a_problem(Dir) of
            true  -> ?WARN("Possible name clash with directory ~p.", [Dir]);
            false -> ok
        end
    end,
    lists:foreach(F, AllDirs).

is_a_problem("eunit") -> true;
is_a_problem("common_test") -> true;
is_a_problem(_) -> false.

