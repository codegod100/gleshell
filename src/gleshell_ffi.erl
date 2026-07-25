%% Erlang FFI for gleshell: REPL I/O, cwd, env, external processes.
-module(gleshell_ffi).
-export([
    get_line/1,
    set_cwd/1,
    get_cwd/0,
    getenv/1,
    setenv/2,
    run_cmd/2,
    which/1,
    home_dir/0
]).

-spec get_line(binary()) -> {ok, binary()} | {error, binary()}.
get_line(Prompt) when is_binary(Prompt) ->
    %% OTP may return a charlist or a UTF-8 binary depending on the
    %% standard_io encoding / binary options — accept both.
    case io:get_line(unicode:characters_to_list(Prompt)) of
        eof ->
            {error, <<"eof">>};
        {error, _} ->
            {error, <<"io_error">>};
        Line when is_list(Line); is_binary(Line) ->
            Bin = unicode:characters_to_binary(Line),
            Stripped = string:trim(Bin, trailing, [$\n, $\r]),
            {ok, Stripped}
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
