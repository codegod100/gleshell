%% Erlang FFI for gleshell: REPL I/O, cwd, env, external processes.
-module(gleshell_ffi).
-export([
    get_line/1,
    parse_line/2,
    run_as_shell/1,
    spawn_shell/2,
    set_cwd/1,
    get_cwd/0,
    getenv/1,
    setenv/2,
    run_cmd/2,
    which/1,
    home_dir/0,
    stdout_isatty/0
]).

%% Read a line with edlin history support.
%%
%% Use get_until (not get_line): since OTP 26, io:get_line/1 input is not
%% reliably saved in the shell history buffer; get_until is. See OTP #6896
%% and the custom-shell guide.
-spec get_line(binary()) -> {ok, binary()} | {error, binary()}.
get_line(Prompt) when is_binary(Prompt) ->
    PromptChars = unicode:characters_to_list(Prompt),
    case io:request(
        standard_io,
        {get_until, unicode, PromptChars, ?MODULE, parse_line, []}
    ) of
        eof ->
            {error, <<"eof">>};
        {error, _} ->
            {error, <<"io_error">>};
        Line when is_list(Line); is_binary(Line) ->
            Bin = unicode:characters_to_binary(Line),
            Stripped = string:trim(Bin, trailing, [$\n, $\r]),
            {ok, Stripped};
        Other ->
            %% Unexpected shape from a custom/get_until callback.
            try
                Bin = unicode:characters_to_binary(Other),
                Stripped = string:trim(Bin, trailing, [$\n, $\r]),
                {ok, Stripped}
            catch
                _:_ ->
                    {error, <<"io_error">>}
            end
    end.

%% get_until callback: edlin already gathers a full line (with editing /
%% history navigation); accept it as done. Cont starts as [].
-spec parse_line(term(), term()) ->
    {done, eof | string(), list()} | {more, term()}.
parse_line(_Cont, eof) ->
    {done, eof, []};
parse_line(_Cont, Chars) when is_list(Chars) ->
    {done, Chars, []}.

%% Run Fun as the OTP interactive shell process so edlin line editing
%% works: up/down history, Ctrl+R reverse-i-search, word kill, etc.
%% Gleam starts the VM with -noshell, so without this we only get dumb
%% line input and no reverse search.
-spec run_as_shell(fun(() -> term())) -> nil.
run_as_shell(Fun) when is_function(Fun, 0) ->
    enable_shell_history(),
    Parent = self(),
    case try_start_interactive(Parent, Fun) of
        {ok, started} ->
            receive
                {gleshell_shell_done, ok} ->
                    nil;
                {gleshell_shell_done, {error, Class, Reason, Stack}} ->
                    erlang:raise(Class, Reason, Stack)
            end;
        {ok, direct} ->
            configure_line_editor(),
            Fun(),
            nil
    end.

try_start_interactive(Parent, Fun) ->
    %% Empty slogan so we do not print the Erlang system banner.
    _ = application:set_env(stdlib, shell_slogan, "", [{persistent, true}]),
    case shell:start_interactive({gleshell_ffi, spawn_shell, [Parent, Fun]}) of
        ok ->
            {ok, started};
        {error, already_started} ->
            {ok, direct};
        {error, _} ->
            {ok, direct}
    end.

%% MFA entry for user_drv/group: must return the shell pid. Spawned
%% under the group so group_leader is the edlin-enabled group.
-spec spawn_shell(pid(), fun(() -> term())) -> pid().
spawn_shell(Parent, Fun) when is_pid(Parent), is_function(Fun, 0) ->
    spawn(fun() ->
        try
            configure_line_editor(),
            Fun()
        of
            _ ->
                Parent ! {gleshell_shell_done, ok},
                %% Intentional exit reason so user_drv does not print
                %% "Shell process terminated!" and restart us.
                exit(die)
        catch
            Class:Reason:Stack ->
                Parent ! {gleshell_shell_done, {error, Class, Reason, Stack}},
                erlang:raise(Class, Reason, Stack)
        end
    end).

%% Best-effort: unicode IO + save get_until lines into edlin history.
configure_line_editor() ->
    _ = io:setopts([{encoding, unicode}, binary]),
    try
        io:setopts([{line_history, true}])
    catch
        _:_ ->
            ok
    end,
    ok.

enable_shell_history() ->
    case application:get_env(kernel, shell_history_path) of
        {ok, _} ->
            ok;
        undefined ->
            Path = filename:basedir(user_cache, "gleshell-history"),
            _ = application:set_env(
                kernel, shell_history_path, Path, [{persistent, true}]
            ),
            ok
    end,
    case application:get_env(kernel, shell_history) of
        {ok, _} ->
            ok;
        undefined ->
            _ = application:set_env(
                kernel, shell_history, enabled, [{persistent, true}]
            ),
            ok
    end.

-spec set_cwd(binary()) -> {ok, nil} | {error, binary()}.
set_cwd(Path) when is_binary(Path) ->
    case file:set_cwd(unicode:characters_to_list(Path)) of
        ok ->
            {ok, nil};
        {error, Reason} ->
            {error, reason_to_bin(Reason)}
    end.

-spec get_cwd() -> {ok, binary()} | {error, binary()}.
get_cwd() ->
    case file:get_cwd() of
        {ok, Dir} ->
            {ok, unicode:characters_to_binary(Dir)};
        {error, Reason} ->
            {error, reason_to_bin(Reason)}
    end.

-spec getenv(binary()) -> {ok, binary()} | {error, nil}.
getenv(Name) when is_binary(Name) ->
    case os:getenv(unicode:characters_to_list(Name)) of
        false ->
            {error, nil};
        Value ->
            {ok, unicode:characters_to_binary(Value)}
    end.

-spec setenv(binary(), binary()) -> {ok, nil}.
setenv(Name, Value) when is_binary(Name), is_binary(Value) ->
    os:putenv(unicode:characters_to_list(Name), unicode:characters_to_list(Value)),
    {ok, nil}.

-spec which(binary()) -> {ok, binary()} | {error, nil}.
which(Command) when is_binary(Command) ->
    case os:find_executable(unicode:characters_to_list(Command)) of
        false ->
            {error, nil};
        Path ->
            {ok, unicode:characters_to_binary(Path)}
    end.

-spec home_dir() -> {ok, binary()} | {error, binary()}.
home_dir() ->
    case os:getenv("HOME") of
        false ->
            {error, <<"HOME not set">>};
        Home ->
            {ok, unicode:characters_to_binary(Home)}
    end.

%% True when stdout is a terminal (colors are useful).
-spec stdout_isatty() -> boolean().
stdout_isatty() ->
    case io:columns() of
        {ok, _} ->
            true;
        _ ->
            try
                case prim_tty:isatty(stdout) of
                    true -> true;
                    _ -> false
                end
            catch
                _:_ ->
                    false
            end
    end.

%% Run an executable with args; capture stdout+stderr and exit status.
%% Returns {ok, {Status :: integer(), Output :: binary()}} | {error, binary()}.
-spec run_cmd(binary(), [binary()]) -> {ok, {integer(), binary()}} | {error, binary()}.
run_cmd(Command, Args) when is_binary(Command), is_list(Args) ->
    case os:find_executable(unicode:characters_to_list(Command)) of
        false ->
            {error, <<"command not found: ", Command/binary>>};
        Path ->
            PortArgs = [unicode:characters_to_list(A) || A <- Args],
            try
                Port = open_port(
                    {spawn_executable, Path},
                    [
                        binary,
                        exit_status,
                        stderr_to_stdout,
                        use_stdio,
                        stream,
                        {args, PortArgs}
                    ]
                ),
                collect_output(Port, <<>>)
            catch
                _:Reason ->
                    {error, reason_to_bin(Reason)}
            end
    end.

collect_output(Port, Acc) ->
    receive
        {Port, {data, Data}} when is_binary(Data) ->
            collect_output(Port, <<Acc/binary, Data/binary>>);
        {Port, {data, Data}} when is_list(Data) ->
            Bin = unicode:characters_to_binary(Data),
            collect_output(Port, <<Acc/binary, Bin/binary>>);
        {Port, {exit_status, Status}} ->
            {ok, {Status, Acc}}
    after 120_000 ->
        catch port_close(Port),
        {error, <<"command timed out after 120s">>}
    end.

reason_to_bin(Reason) when is_atom(Reason) ->
    atom_to_binary(Reason, utf8);
reason_to_bin(Reason) when is_binary(Reason) ->
    Reason;
reason_to_bin(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).
