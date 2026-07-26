%% Erlang FFI for gleshell: REPL I/O, cwd, env, external processes.
-module(gleshell_ffi).
-include_lib("kernel/include/file.hrl").
-export([
    get_line/1,
    read_user_input/1,
    parse_line/2,
    run_as_shell/1,
    spawn_shell/2,
    set_cwd/1,
    get_cwd/0,
    getenv/1,
    setenv/2,
    list_env/0,
    run_cmd/3,
    run_cmd_tty/3,
    which/1,
    which_all/1,
    realpath/1,
    home_dir/0,
    stdout_isatty/0,
    println/1,
    write/1,
    term_size/0,
    read_key_name/0,
    with_key_mode/1,
    take_output_shown/0,
    clear_output_shown/0,
    complete_word/2,
    history_hint/2,
    history_search/2,
    re_contains/3,
    format_unix_local/1,
    unix_now/0,
    list_processes/0,
    list_port_sockets/1
]).

-define(ESC, 16#1b).
-define(CSI_CLEAR_EOL, "\e[K").
-define(HISTORY_MAX, 2000).
%% Max rows of history matches shown in the Ctrl+R picker (stinkpot-style).
-define(SEARCH_MAX_ROWS, 12).

%% ---------------------------------------------------------------------------
%% Public: write a line (CRLF in raw TTY mode so multi-line output does not
%% staircase — raw mode does not map LF → CR+LF the way cooked mode does).
%% ---------------------------------------------------------------------------

-spec println(binary()) -> nil.
println(Text) when is_binary(Text) ->
    case get(gleshell_raw) of
        true ->
            io:put_chars([to_crlf(Text), <<"\r\n">>]),
            nil;
        _ ->
            io:put_chars([Text, $\n]),
            nil
    end.

%% Write text without an automatic trailing newline. ANSI sequences are passed
%% through unchanged. In raw TTY mode, bare LFs become CRLF so lines do not
%% staircase (same as println/1).
-spec write(binary()) -> nil.
write(Text) when is_binary(Text) ->
    case get(gleshell_raw) of
        true ->
            io:put_chars(to_crlf(Text)),
            nil;
        _ ->
            io:put_chars(Text),
            nil
    end.

%% Terminal size when stdout is a TTY. Defaults to 24×80 if the driver omits a
%% dimension. Error when stdout is not a terminal (pager should dump instead).
-spec term_size() -> {ok, {integer(), integer()}} | {error, nil}.
term_size() ->
    case stdout_isatty() of
        false ->
            {error, nil};
        true ->
            Rows =
                case io:rows() of
                    {ok, R} when is_integer(R), R > 0 ->
                        R;
                    _ ->
                        24
                end,
            Cols =
                case io:columns() of
                    {ok, C} when is_integer(C), C > 0 ->
                        C;
                    _ ->
                        80
                end,
            {ok, {Rows, Cols}}
    end.

%% Run Fun with the TTY in single-key (non-canonical, no-echo) mode when the
%% REPL is not already raw. Restores termios afterwards. Prefer wrapping a
%% whole pager session rather than each keystroke.
-spec with_key_mode(fun(() -> term())) -> term().
with_key_mode(Fun) when is_function(Fun, 0) ->
    case get(gleshell_raw) of
        true ->
            Fun();
        _ ->
            case stdout_isatty() of
                false ->
                    Fun();
                true ->
                    case stty_save() of
                        {ok, Saved} ->
                            _ = stty_run(["-icanon", "-echo", "min", "1", "time", "0"]),
                            try
                                Fun()
                            after
                                stty_restore(Saved)
                            end;
                        _ ->
                            Fun()
                    end
            end
    end.

%% Blocking single-key read for the builtin pager. Returns a short name:
%% "up" | "down" | "left" | "right" | "home" | "end" | "page_up" | "page_down"
%% | "enter" | "backspace" | "tab" | "ctrl_c" | "ctrl_l" | "space" | "eof"
%% | single printable grapheme ("q", "j", "G", …) | "other".
%%
%% Call inside `with_key_mode/1` when not already in the raw REPL, so cooked
%% TTYs (e.g. `gleshell -c '… | less'`) still deliver keys one at a time.
-spec read_key_name() -> {ok, binary()} | {error, binary()}.
read_key_name() ->
    try
        {ok, key_to_name(read_key())}
    catch
        _:Reason ->
            {error, reason_to_bin(Reason)}
    end.

key_to_name(eof) ->
    <<"eof">>;
key_to_name(enter) ->
    <<"enter">>;
key_to_name(tab) ->
    <<"tab">>;
key_to_name(backspace) ->
    <<"backspace">>;
key_to_name(delete) ->
    <<"delete">>;
key_to_name(up) ->
    <<"up">>;
key_to_name(down) ->
    <<"down">>;
key_to_name(left) ->
    <<"left">>;
key_to_name(right) ->
    <<"right">>;
key_to_name(home) ->
    <<"home">>;
key_to_name('end') ->
    <<"end">>;
key_to_name(page_up) ->
    <<"page_up">>;
key_to_name(page_down) ->
    <<"page_down">>;
key_to_name(ctrl_c) ->
    <<"ctrl_c">>;
key_to_name(ctrl_l) ->
    <<"ctrl_l">>;
key_to_name(ctrl_a) ->
    <<"ctrl_a">>;
key_to_name(ctrl_e) ->
    <<"ctrl_e">>;
key_to_name(ctrl_d) ->
    <<"ctrl_d">>;
key_to_name(ctrl_k) ->
    <<"ctrl_k">>;
key_to_name(ctrl_u) ->
    <<"ctrl_u">>;
key_to_name(ctrl_w) ->
    <<"ctrl_w">>;
key_to_name(ctrl_r) ->
    <<"ctrl_r">>;
key_to_name(ctrl_f) ->
    <<"ctrl_f">>;
key_to_name(ctrl_p) ->
    <<"ctrl_p">>;
key_to_name(ctrl_n) ->
    <<"ctrl_n">>;
key_to_name(alt_f) ->
    <<"alt_f">>;
key_to_name(ctrl_g) ->
    <<"ctrl_g">>;
key_to_name(esc) ->
    <<"esc">>;
key_to_name({char, 32}) ->
    <<"space">>;
key_to_name({char, C}) when is_integer(C), C >= 32 ->
    unicode:characters_to_binary([C]);
key_to_name({error, _}) ->
    <<"eof">>;
key_to_name(_) ->
    <<"other">>.

%% Normalize newlines to CRLF without turning existing \r\n into \r\r\n.
to_crlf(Bin) when is_binary(Bin) ->
    B1 = binary:replace(Bin, <<"\r\n">>, <<"\n">>, [global]),
    B2 = binary:replace(B1, <<"\r">>, <<"\n">>, [global]),
    binary:replace(B2, <<"\n">>, <<"\r\n">>, [global]).

%% ---------------------------------------------------------------------------
%% Public: read a line (syntax-highlighted when raw TTY mode is active)
%% ---------------------------------------------------------------------------

-spec get_line(binary()) -> {ok, binary()} | {error, binary()}.
get_line(Prompt) when is_binary(Prompt) ->
    case get(gleshell_raw) of
        true ->
            raw_get_line(Prompt);
        _ ->
            classic_get_line(Prompt)
    end.

%% Edlin / get_until path (non-TTY or when raw mode unavailable).
classic_get_line(Prompt) ->
    PromptChars = unicode:characters_to_list(Prompt),
    case io:request(
        standard_io,
        {get_until, unicode, PromptChars, ?MODULE, parse_line, []}
    ) of
        eof ->
            {error, <<"eof">>};
        {error, interrupted} ->
            %% Ctrl+C while reading: cancel line, keep the REPL alive.
            {error, <<"interrupted">>};
        {error, _} ->
            {error, <<"io_error">>};
        Line when is_list(Line); is_binary(Line) ->
            Bin = unicode:characters_to_binary(Line),
            Stripped = string:trim(Bin, trailing, [$\n, $\r]),
            {ok, Stripped};
        Other ->
            try
                Bin = unicode:characters_to_binary(Other),
                Stripped = string:trim(Bin, trailing, [$\n, $\r]),
                {ok, Stripped}
            catch
                _:_ ->
                    {error, <<"io_error">>}
            end
    end.

%% get_until callback: edlin already gathers a full line.
-spec parse_line(term(), term()) ->
    {done, eof | string(), list()} | {more, term()}.
parse_line(_Cont, eof) ->
    {done, eof, []};
parse_line(_Cont, Chars) when is_list(Chars) ->
    {done, Chars, []}.

%% ---------------------------------------------------------------------------
%% Public: multi-line user input for the `input` builtin
%%
%% Interactive (raw REPL or TTY): read until Ctrl+D / EOF so the user can
%% paste a blob and end with Ctrl+D, e.g. `input | from json`.
%% Non-TTY (piped stdin): read the whole stream — `printf '…' | gle -c 'input | …'`.
%% Optional prompt is printed first (empty prompt = silent).
%% ---------------------------------------------------------------------------

-spec read_user_input(binary()) -> {ok, binary()} | {error, binary()}.
read_user_input(Prompt) when is_binary(Prompt) ->
    case Prompt of
        <<>> ->
            ok;
        _ ->
            %% Prompt on its own line so paste starts cleanly below it.
            case get(gleshell_raw) of
                true ->
                    io:put_chars(to_crlf(<<Prompt/binary, "\n">>));
                _ ->
                    io:put_chars(<<Prompt/binary, "\n">>)
            end
    end,
    try
        case get(gleshell_raw) of
            true ->
                read_input_raw([]);
            _ ->
                case stdin_isatty() of
                    true ->
                        read_input_lines([]);
                    false ->
                        read_input_stream([])
                end
        end
    catch
        _:Reason ->
            {error, reason_to_bin(Reason)}
    end.

%% Raw-mode multi-line: echo printable chars, Enter → newline, Ctrl+D ends.
read_input_raw(Acc) ->
    case read_key() of
        eof ->
            io:put_chars("\r\n"),
            {ok, codepoints_to_bin(lists:reverse(Acc))};
        ctrl_d ->
            io:put_chars("\r\n"),
            {ok, codepoints_to_bin(lists:reverse(Acc))};
        ctrl_c ->
            io:put_chars("^C\r\n"),
            {error, <<"interrupted">>};
        enter ->
            io:put_chars("\r\n"),
            read_input_raw([$\n | Acc]);
        backspace ->
            case Acc of
                [] ->
                    read_input_raw(Acc);
                [$\n | _] ->
                    %% Do not erase previous lines with a simple \b.
                    read_input_raw(Acc);
                [_ | Rest] ->
                    io:put_chars("\b \b"),
                    read_input_raw(Rest)
            end;
        {char, C} when is_integer(C), C >= 32 ->
            io:put_chars(unicode:characters_to_binary([C])),
            read_input_raw([C | Acc]);
        {error, _} ->
            io:put_chars("\r\n"),
            {error, <<"io_error">>};
        _Other ->
            read_input_raw(Acc)
    end.

codepoints_to_bin(Cs) ->
    unicode:characters_to_binary(Cs).

%% Cooked/edlin TTY: line-at-a-time until EOF (Ctrl+D on empty line).
read_input_lines(Acc) ->
    case io:get_line("") of
        eof ->
            {ok, iolist_to_binary(lists:reverse(Acc))};
        {error, interrupted} ->
            {error, <<"interrupted">>};
        {error, _} ->
            {error, <<"io_error">>};
        Line when is_list(Line); is_binary(Line) ->
            Bin = unicode:characters_to_binary(Line),
            read_input_lines([Bin | Acc]);
        Other ->
            try
                Bin = unicode:characters_to_binary(Other),
                read_input_lines([Bin | Acc])
            catch
                _:_ ->
                    {error, <<"io_error">>}
            end
    end.

%% Piped / non-TTY stdin: drain the whole stream.
read_input_stream(Acc) ->
    case io:get_chars("", 8192) of
        eof ->
            {ok, iolist_to_binary(lists:reverse(Acc))};
        {error, Reason} ->
            {error, reason_to_bin(Reason)};
        Data when is_binary(Data) ->
            read_input_stream([Data | Acc]);
        Data when is_list(Data) ->
            read_input_stream([unicode:characters_to_binary(Data) | Acc]);
        Other ->
            try
                Bin = unicode:characters_to_binary(Other),
                read_input_stream([Bin | Acc])
            catch
                _:_ ->
                    {error, <<"io_error">>}
            end
    end.

-spec stdin_isatty() -> boolean().
stdin_isatty() ->
    try
        case prim_tty:isatty(stdin) of
            true ->
                true;
            _ ->
                false
        end
    catch
        _:_ ->
            %% Fallback: if we cannot tell, prefer stream read so pipes work.
            false
    end.

%% ---------------------------------------------------------------------------
%% Shell bootstrap: prefer OTP raw mode for live syntax highlighting.
%% Falls back to edlin interactive shell when raw is unavailable.
%%
%% Ctrl+C: the BEAM default opens the BREAK menu (a = abort → process exit).
%% Re-exec once with +Bc so Ctrl+C is delivered as a character to our editor
%% (cancel line) instead of killing the shell. See erl(1) +B.
%% ---------------------------------------------------------------------------

-spec run_as_shell(fun(() -> term())) -> nil.
run_as_shell(Fun) when is_function(Fun, 0) ->
    case ensure_plus_bc() of
        {parent, Port} ->
            %% Child owns the TTY; we only wait for its exit status.
            receive
                {Port, {exit_status, Status}} ->
                    erlang:halt(Status)
            end;
        child ->
            enable_shell_history(),
            case try_start_raw() of
                true ->
                    put(gleshell_raw, true),
                    load_line_history(),
                    configure_line_editor(),
                    try
                        Fun()
                    after
                        save_line_history()
                    end,
                    nil;
                false ->
                    erase(gleshell_raw),
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
                    end
            end
    end.

%% Ensure the emulator was started with +Bc (Ctrl+C → char, not BREAK/abort).
%% Returns `child` when this process should run the REPL, or `{parent, Port}`
%% when we re-exec'd and should wait on the child.
-spec ensure_plus_bc() -> child | {parent, port()}.
ensure_plus_bc() ->
    case os:getenv("GLESHELL_PLUS_BC") of
        "1" ->
            child;
        _ ->
            case already_has_plus_bc() of
                true ->
                    os:putenv("GLESHELL_PLUS_BC", "1"),
                    child;
                false ->
                    reexec_with_plus_bc()
            end
    end.

already_has_plus_bc() ->
    lists:any(
        fun(Var) ->
            case os:getenv(Var) of
                false ->
                    false;
                Flags ->
                    string:find(Flags, "+Bc") =/= nomatch
            end
        end,
        ["ERL_AFLAGS", "ERL_FLAGS", "ERL_ZFLAGS"]
    ).

reexec_with_plus_bc() ->
    os:putenv("GLESHELL_PLUS_BC", "1"),
    case os:getenv("ERL_AFLAGS") of
        false ->
            os:putenv("ERL_AFLAGS", "+Bc");
        Flags ->
            case string:find(Flags, "+Bc") of
                nomatch ->
                    os:putenv("ERL_AFLAGS", "+Bc " ++ Flags);
                _ ->
                    ok
            end
    end,
    case os:find_executable("erl") of
        false ->
            %% No erl on PATH — continue without +Bc (BREAK menu may appear).
            child;
        Erl ->
            Pa = lists:flatmap(fun(D) -> ["-pa", D] end, code:get_path()),
            Extra = init:get_plain_arguments(),
            Args =
                ["+Bc", "-noshell"] ++
                Pa ++
                ["-eval", "gleshell@@main:run(gleshell)", "-extra" | Extra],
            try
                Port = open_port(
                    {spawn_executable, Erl},
                    [exit_status, nouse_stdio, {args, Args}]
                ),
                {parent, Port}
            catch
                _:_ ->
                    child
            end
    end.

try_start_raw() ->
    case stdout_isatty() of
        false ->
            false;
        true ->
            case catch shell:start_interactive({noshell, raw}) of
                ok ->
                    true;
                {error, already_started} ->
                    %% Cannot switch an existing interactive shell into raw.
                    false;
                _ ->
                    false
            end
    end.

try_start_interactive(Parent, Fun) ->
    _ = application:set_env(stdlib, shell_slogan, "", [{persistent, true}]),
    case shell:start_interactive({gleshell_ffi, spawn_shell, [Parent, Fun]}) of
        ok ->
            {ok, started};
        {error, already_started} ->
            {ok, direct};
        {error, _} ->
            {ok, direct}
    end.

-spec spawn_shell(pid(), fun(() -> term())) -> pid().
spawn_shell(Parent, Fun) when is_pid(Parent), is_function(Fun, 0) ->
    spawn(fun() ->
        try
            configure_line_editor(),
            Fun()
        of
            _ ->
                Parent ! {gleshell_shell_done, ok},
                exit(die)
        catch
            Class:Reason:Stack ->
                Parent ! {gleshell_shell_done, {error, Class, Reason, Stack}},
                erlang:raise(Class, Reason, Stack)
        end
    end).

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

%% ---------------------------------------------------------------------------
%% Raw-mode line editor with Nushell-style syntax highlighting
%% ---------------------------------------------------------------------------
%%
%% Buffer model: Left is graphemes before the cursor (reversed),
%% Right is graphemes after the cursor (normal order).
%% History is a list of binaries (newest first).

raw_get_line(Prompt) when is_binary(Prompt) ->
    PromptList = unicode:characters_to_list(Prompt),
    %% Densify every prompt: drop blanks so ↑ never lands on an empty slot
    %% even if an older session or bug left one in the process dict.
    History = sanitize_history(
        case get(gleshell_history) of
            L when is_list(L) -> L;
            _ -> []
        end
    ),
    put(gleshell_history, History),
    put(gleshell_input_rows, 1),
    redraw(PromptList, [], []),
    raw_loop(PromptList, [], [], History, 0, <<>>).

%% HistPos: 0 = editing current buffer; N>0 = viewing Nth history entry.
%% Saved: buffer saved when first entering history navigation.
raw_loop(Prompt, Left, Right, History, HistPos, Saved) ->
    case read_key() of
        eof ->
            io:put_chars("\r\n"),
            {error, <<"eof">>};
        {error, _} ->
            io:put_chars("\r\n"),
            {error, <<"io_error">>};
        enter ->
            Line = buffer_to_bin(Left, Right),
            io:put_chars("\r\n"),
            push_history(Line),
            {ok, Line};
        {char, C} when is_integer(C), C >= 32, C =/= 127 ->
            %% Printable Unicode codepoint
            NewLeft = [C | Left],
            redraw(Prompt, NewLeft, Right),
            raw_loop(Prompt, NewLeft, Right, History, 0, <<>>);
        backspace ->
            case Left of
                [] ->
                    raw_loop(Prompt, Left, Right, History, HistPos, Saved);
                [_ | Rest] ->
                    redraw(Prompt, Rest, Right),
                    raw_loop(Prompt, Rest, Right, History, 0, <<>>)
            end;
        delete ->
            case Right of
                [] ->
                    raw_loop(Prompt, Left, Right, History, HistPos, Saved);
                [_ | Rest] ->
                    redraw(Prompt, Left, Rest),
                    raw_loop(Prompt, Left, Rest, History, 0, <<>>)
            end;
        left ->
            case Left of
                [] ->
                    raw_loop(Prompt, Left, Right, History, HistPos, Saved);
                [C | Rest] ->
                    redraw(Prompt, Rest, [C | Right]),
                    raw_loop(Prompt, Rest, [C | Right], History, HistPos, Saved)
            end;
        right ->
            case Right of
                [] ->
                    %% At end of line: accept greyed-out history hint (Nu/fish).
                    accept_history_hint(Prompt, Left, Right, History, HistPos, Saved);
                [C | Rest] ->
                    redraw(Prompt, [C | Left], Rest),
                    raw_loop(Prompt, [C | Left], Rest, History, HistPos, Saved)
            end;
        home ->
            NewRight = lists:reverse(Left) ++ Right,
            redraw(Prompt, [], NewRight),
            raw_loop(Prompt, [], NewRight, History, HistPos, Saved);
        'end' ->
            case Right of
                [] ->
                    %% Already at end: accept full history hint if present.
                    accept_history_hint(Prompt, Left, Right, History, HistPos, Saved);
                _ ->
                    NewLeft = lists:reverse(Right) ++ Left,
                    redraw(Prompt, NewLeft, []),
                    raw_loop(Prompt, NewLeft, [], History, HistPos, Saved)
            end;
        up ->
            hist_nav(Prompt, Left, Right, History, HistPos, Saved, 1);
        down ->
            hist_nav(Prompt, Left, Right, History, HistPos, Saved, -1);
        ctrl_a ->
            NewRight = lists:reverse(Left) ++ Right,
            redraw(Prompt, [], NewRight),
            raw_loop(Prompt, [], NewRight, History, HistPos, Saved);
        ctrl_e ->
            case Right of
                [] ->
                    accept_history_hint(Prompt, Left, Right, History, HistPos, Saved);
                _ ->
                    NewLeft = lists:reverse(Right) ++ Left,
                    redraw(Prompt, NewLeft, []),
                    raw_loop(Prompt, NewLeft, [], History, HistPos, Saved)
            end;
        ctrl_f ->
            %% Emacs-style forward-char; at EOL accepts history hint (like Nu).
            case Right of
                [] ->
                    accept_history_hint(Prompt, Left, Right, History, HistPos, Saved);
                [C | Rest] ->
                    redraw(Prompt, [C | Left], Rest),
                    raw_loop(Prompt, [C | Left], Rest, History, HistPos, Saved)
            end;
        alt_f ->
            %% Accept one word of the history hint (Nu Alt+F).
            accept_history_hint_word(Prompt, Left, Right, History, HistPos, Saved);
        ctrl_u ->
            redraw(Prompt, [], Right),
            raw_loop(Prompt, [], Right, History, 0, <<>>);
        ctrl_k ->
            redraw(Prompt, Left, []),
            raw_loop(Prompt, Left, [], History, 0, <<>>);
        ctrl_w ->
            {NewLeft, _} = kill_word(Left),
            redraw(Prompt, NewLeft, Right),
            raw_loop(Prompt, NewLeft, Right, History, 0, <<>>);
        ctrl_d ->
            case {Left, Right} of
                {[], []} ->
                    io:put_chars("\r\n"),
                    {error, <<"eof">>};
                {_, []} ->
                    raw_loop(Prompt, Left, Right, History, HistPos, Saved);
                {_, [_ | Rest]} ->
                    redraw(Prompt, Left, Rest),
                    raw_loop(Prompt, Left, Rest, History, 0, <<>>)
            end;
        ctrl_c ->
            %% Cancel current line (like bash) and return empty.
            io:put_chars("^C\r\n"),
            {ok, <<>>};
        ctrl_l ->
            io:put_chars("\e[H\e[2J"),
            redraw(Prompt, Left, Right),
            raw_loop(Prompt, Left, Right, History, HistPos, Saved);
        ctrl_r ->
            reverse_search(Prompt, Left, Right, History);
        tab ->
            tab_complete(Prompt, Left, Right, History, HistPos, Saved);
        _Other ->
            raw_loop(Prompt, Left, Right, History, HistPos, Saved)
    end.

%% ---------------------------------------------------------------------------
%% Tab: command + filename completion (token under cursor)
%% ---------------------------------------------------------------------------
%%
%% Command position (start of line / after | ; & =): complete builtins and
%% PATH executables. Path-like command words (./foo, /bin/ls, ~/x) still use
%% filename completion. Elsewhere: filename completion as before.
%%
%% One match → insert it (commands get a trailing space; dirs get /).
%% Several matches → extend the longest common prefix; if that does not
%% advance the buffer, list candidates under the line and redraw.

tab_complete(Prompt, Left, Right, History, HistPos, Saved) ->
    {PrefixRev, Word} = word_before_cursor(Left),
    {Matches, Kind} = completions_for(PrefixRev, Word),
    case Matches of
        [] ->
            beep(),
            raw_loop(Prompt, Left, Right, History, HistPos, Saved);
        [Only] ->
            Insert = finalize_completion(Only, Kind),
            NewLeft = apply_completed_word(PrefixRev, Insert),
            redraw(Prompt, NewLeft, Right),
            raw_loop(Prompt, NewLeft, Right, History, 0, <<>>);
        _ ->
            Common = longest_common_prefix(Matches),
            case Common =/= Word andalso length(Common) >= length(Word) of
                true ->
                    NewLeft = apply_completed_word(PrefixRev, Common),
                    redraw(Prompt, NewLeft, Right),
                    raw_loop(Prompt, NewLeft, Right, History, 0, <<>>);
                false ->
                    show_completions(Matches),
                    redraw(Prompt, Left, Right),
                    raw_loop(Prompt, Left, Right, History, HistPos, Saved)
            end
    end.

%% Test/helper: return {Matches, Kind} for a buffer prefix and word.
%% Prefix is the text *before* the word being completed (not reversed).
%% Kind is <<"command">> | <<"path">>.
-spec complete_word(binary(), binary()) -> {list(binary()), binary()}.
complete_word(PrefixBin, WordBin) when is_binary(PrefixBin), is_binary(WordBin) ->
    Prefix = unicode:characters_to_list(PrefixBin),
    Word = unicode:characters_to_list(WordBin),
    PrefixRev = lists:reverse(Prefix),
    {Matches, Kind} = completions_for(PrefixRev, Word),
    KindBin =
        case Kind of
            command -> <<"command">>;
            path -> <<"path">>
        end,
    {
        [unicode:characters_to_binary(M) || M <- Matches],
        KindBin
    }.

%% Trailing space after a unique command so the user can type args next.
finalize_completion(Word, command) ->
    case lists:last(Word) of
        $/ -> Word;
        $\s -> Word;
        _ -> Word ++ " "
    end;
finalize_completion(Word, path) ->
    Word.

completions_for(PrefixRev, Word) ->
    case is_command_position(PrefixRev) andalso not is_path_like_word(Word) of
        true ->
            {command_completions(Word), command};
        false ->
            {filename_completions(Word), path}
    end.

%% Command position: empty prefix, or last non-space before the word is a
%% pipeline/statement separator or assignment (`let x = …`).
is_command_position(PrefixRev) ->
    Before = string:trim(lists:reverse(PrefixRev), trailing),
    case Before of
        [] ->
            true;
        _ ->
            case lists:last(Before) of
                $| -> true;
                $; -> true;
                $& -> true;
                $= -> true;
                _ -> false
            end
    end.

%% ./script, ../bin/x, /usr/bin/ls, ~/bin/foo — complete as paths even as cmds.
is_path_like_word([]) ->
    false;
is_path_like_word(Word) ->
    lists:member($/, Word) orelse lists:member($\\, Word) orelse hd(Word) =:= $~.

%% Builtins + keywords + PATH executables matching Word as a prefix.
command_completions(Word) ->
    Builtins = [
        N
     || N <- builtin_command_names(),
        lists:prefix(Word, N)
    ],
    Keywords = [
        N
     || N <- ["let"],
        lists:prefix(Word, N)
    ],
    PathCmds =
        case Word of
            %% Empty prefix: skip PATH dump (can be thousands of names).
            [] ->
                [];
            _ ->
                path_command_completions(Word)
        end,
    lists:usort(Builtins ++ Keywords ++ PathCmds).

%% Prefer live Gleam registry; fall back if the module is not loaded yet.
builtin_command_names() ->
    try
        Names = 'gleshell@builtins':names(),
        [to_charlist(N) || N <- Names]
    catch
        _:_ ->
            fallback_builtin_names()
    end.

to_charlist(B) when is_binary(B) ->
    unicode:characters_to_list(B);
to_charlist(L) when is_list(L) ->
    L.

fallback_builtin_names() ->
    [
        "about", "append", "cat", "cd", "columns", "count", "describe", "echo",
        "env", "exit", "filter", "find", "first", "flatten", "from", "get",
        "help", "identity", "ignore", "input", "is-empty", "is_empty", "keys",
        "last", "length", "less", "lines", "ls", "now", "open", "prepend",
        "print", "ps", "pwd", "quit", "range", "reverse", "save", "select",
        "skip", "sort-by", "sort_by", "sys", "table", "take", "to", "type",
        "typeof", "uniq", "unwrap", "values", "where", "which", "whyport",
        "wrap"
    ].

%% Executable basenames on PATH that match Prefix (deduped, sorted).
path_command_completions(Prefix) ->
    case os:getenv("PATH") of
        false ->
            [];
        PathStr ->
            Dirs = string:tokens(PathStr, path_sep()),
            Acc = lists:foldl(
                fun(Dir, Seen) ->
                    collect_path_cmds(Dir, Prefix, Seen)
                end,
                #{},
                Dirs
            ),
            lists:sort(maps:keys(Acc))
    end.

collect_path_cmds(Dir, Prefix, Seen) ->
    case file:list_dir(Dir) of
        {ok, Names} ->
            lists:foldl(
                fun(Name, Acc) ->
                    case
                        lists:prefix(Prefix, Name)
                        andalso show_dotfile(Prefix, Name)
                        andalso not maps:is_key(Name, Acc)
                        andalso is_executable_file(filename:join(Dir, Name))
                    of
                        true ->
                            Acc#{Name => true};
                        false ->
                            Acc
                    end
                end,
                Seen,
                Names
            );
        {error, _} ->
            Seen
    end.

beep() ->
    io:put_chars([7]).

%% Left is graphemes before the cursor in reverse order.
%% Returns {PrefixRev, WordForward} where Word is the path token.
word_before_cursor(Left) ->
    take_completion_word(Left, []).

%% Acc: walking Left (reversed buffer) with [C|Acc] rebuilds the word forward.
take_completion_word([], Acc) ->
    {[], Acc};
take_completion_word([C | Rest], Acc) ->
    case is_completion_break(C) of
        true ->
            {[C | Rest], Acc};
        false ->
            take_completion_word(Rest, [C | Acc])
    end.

is_completion_break(C) when C =:= $\s; C =:= $\t ->
    true;
is_completion_break(C) when C =:= $|; C =:= $;; C =:= $& ->
    true;
is_completion_break(C) when C =:= $(; C =:= $); C =:= $[; C =:= $] ->
    true;
is_completion_break(C) when C =:= ${; C =:= $}; C =:= $<; C =:= $> ->
    true;
is_completion_break(C) when C =:= $'; C =:= $" ->
    true;
is_completion_break(_) ->
    false.

apply_completed_word(PrefixRev, Word) ->
    lists:reverse(Word) ++ PrefixRev.

%% Return sorted completion strings (as typed, with ~ preserved; dirs end in /).
filename_completions(Word) ->
    {ListDirTyped, Base, InsertPrefix} = split_completion_word(Word),
    ListDir = expand_home_path(ListDirTyped),
    case file:list_dir(ListDir) of
        {ok, Names0} ->
            Names = lists:sort(Names0),
            [
                InsertPrefix ++ maybe_dir_slash(ListDir, Name)
             || Name <- Names,
                lists:prefix(Base, Name),
                show_dotfile(Base, Name)
            ];
        {error, _} ->
            []
    end.

%% Hide dotfiles unless the partial name already starts with '.'.
show_dotfile([$. | _], _) ->
    true;
show_dotfile(_, [$. | _]) ->
    false;
show_dotfile(_, _) ->
    true.

maybe_dir_slash(ListDir, Name) ->
    case filelib:is_dir(filename:join(ListDir, Name)) of
        true -> Name ++ "/";
        false -> Name
    end.

%% Split a path word into {dir_to_list, basename_prefix, insert_prefix}.
%% insert_prefix is the directory part as the user typed it (incl. trailing /).
split_completion_word(Word) ->
    case rsplit_path(Word) of
        {none, Base} ->
            {".", Base, ""};
        {Dir, Base} ->
            ListDir =
                case Dir of
                    "" -> "/";
                    _ -> Dir
                end,
            InsertPrefix =
                case Dir of
                    "" -> "/";
                    _ -> Dir ++ "/"
                end,
            {ListDir, Base, InsertPrefix}
    end.

%% Rightmost / splits directory from the partial basename.
rsplit_path(Word) ->
    rsplit_path(lists:reverse(Word), []).

rsplit_path([], Acc) ->
    {none, Acc};
rsplit_path([$/ | Rest], Acc) ->
    {lists:reverse(Rest), Acc};
rsplit_path([C | Rest], Acc) ->
    rsplit_path(Rest, [C | Acc]).

expand_home_path(Path) ->
    case Path of
        "~" ->
            home_path_string();
        [$~, $/ | More] ->
            home_path_string() ++ "/" ++ More;
        _ ->
            Path
    end.

home_path_string() ->
    case os:getenv("HOME") of
        false -> ".";
        Home when is_list(Home) -> Home;
        Home when is_binary(Home) -> unicode:characters_to_list(Home)
    end.

longest_common_prefix([]) ->
    "";
longest_common_prefix([H | T]) ->
    lists:foldl(fun lcp2/2, H, T).

lcp2(A, B) ->
    lcp2(A, B, []).

lcp2([X | As], [X | Bs], Acc) ->
    lcp2(As, Bs, [X | Acc]);
lcp2(_, _, Acc) ->
    lists:reverse(Acc).

show_completions(Matches) ->
    io:put_chars("\r\n"),
    case io:columns() of
        {ok, Cols} when is_integer(Cols), Cols > 8 ->
            print_completion_columns(Matches, Cols);
        _ ->
            io:put_chars(lists:join("  ", Matches)),
            io:put_chars("\r\n")
    end.

print_completion_columns(Matches, Cols) ->
    MaxLen = lists:max([0 | [length(M) || M <- Matches]]),
    Width = MaxLen + 2,
    PerRow = max(1, Cols div Width),
    print_rows(Matches, PerRow, Width).

print_rows([], _PerRow, _Width) ->
    ok;
print_rows(Matches, PerRow, Width) ->
    {Row, Rest} = take_n(Matches, PerRow, []),
    Line = [
        pad_cell(M, Width)
     || M <- Row
    ],
    io:put_chars([Line, "\r\n"]),
    print_rows(Rest, PerRow, Width).

take_n(List, 0, Acc) ->
    {lists:reverse(Acc), List};
take_n([], _N, Acc) ->
    {lists:reverse(Acc), []};
take_n([H | T], N, Acc) ->
    take_n(T, N - 1, [H | Acc]).

pad_cell(S, Width) ->
    Pad = Width - length(S),
    case Pad > 0 of
        true -> S ++ lists:duplicate(Pad, $\s);
        false -> S ++ "  "
    end.

hist_nav(Prompt, Left, Right, History, HistPos, Saved, Delta) ->
    case hist_seek(History, HistPos, Delta) of
        stay ->
            raw_loop(Prompt, Left, Right, History, HistPos, Saved);
        draft ->
            %% Restore the buffer from before history navigation.
            {L, R} = bin_to_buffer(Saved),
            redraw(Prompt, L, R),
            raw_loop(Prompt, L, R, History, 0, <<>>);
        {NewPos, Entry} ->
            NewSaved = case HistPos of
                0 -> buffer_to_bin(Left, Right);
                _ -> Saved
            end,
            %% Belt-and-suspenders: never paint a blank recall (dense History
            %% should already exclude these).
            case history_blank(Entry) of
                true ->
                    hist_nav(Prompt, Left, Right, History, NewPos, NewSaved, Delta);
                false ->
                    {L, R} = bin_to_buffer(Entry),
                    redraw(Prompt, L, R),
                    raw_loop(Prompt, L, R, History, NewPos, NewSaved)
            end
    end.

%% Walk history in `Delta` direction, skipping blank/whitespace-only entries.
%% Delta > 0 = older (↑); Delta < 0 = newer (↓). Position 0 is the live draft.
%% History is expected newest-first and already densified (no blanks), but we
%% still skip blanks so a stale list cannot surface an empty ↑ recall.
hist_seek(_History, 0, Delta) when Delta < 0 ->
    stay;
hist_seek(History, HistPos, Delta) when Delta > 0 ->
    hist_seek_loop(History, HistPos + 1, 1, length(History));
hist_seek(History, HistPos, Delta) when Delta < 0 ->
    hist_seek_loop(History, HistPos - 1, -1, length(History)).

hist_seek_loop(_History, Pos, Step, _Len) when Step < 0, Pos =< 0 ->
    draft;
hist_seek_loop(_History, Pos, Step, Len) when Step > 0, Pos > Len ->
    stay;
hist_seek_loop(History, Pos, Step, Len) when Pos >= 1, Pos =< Len ->
    Entry = lists:nth(Pos, History),
    case history_blank(Entry) of
        true ->
            hist_seek_loop(History, Pos + Step, Step, Len);
        false ->
            {Pos, Entry}
    end;
hist_seek_loop(_History, _Pos, _Step, _Len) ->
    stay.

%% ---------------------------------------------------------------------------
%% Ctrl+R reverse history search — stinkpot-style multi-match TUI
%% (https://tangled.org/oppi.li/stinkpot)
%%
%% Fuzzy filter over newest-first history, list up to 12 rows, ↑/↓ move,
%% Enter/Tab accept onto the line (does not execute), Esc/Ctrl+C/Ctrl+G cancel.
%% Runs on the alternate screen so the REPL is restored cleanly.
%% ---------------------------------------------------------------------------

reverse_search(Prompt, Left, Right, History) ->
    %% Seed query from the current buffer (like stinkpot's READLINE_LINE).
    QueryChars =
        case unicode:characters_to_list(lists:reverse(Left) ++ Right) of
            L when is_list(L) -> L;
            _ -> []
        end,
    Candidates = uniq_history(History),
    Filtered = history_search_filter(Candidates, QueryChars),
    enter_alt_screen(),
    Result = reverse_search_loop(Candidates, QueryChars, Filtered, 0),
    leave_alt_screen(),
    put(gleshell_input_rows, 1),
    case Result of
        {ok, Selected} when is_binary(Selected) ->
            reverse_search_accept(Prompt, History, Selected);
        cancel ->
            redraw(Prompt, Left, Right),
            raw_loop(Prompt, Left, Right, History, 0, <<>>);
        eof ->
            io:put_chars("\r\n"),
            {error, <<"eof">>};
        _ ->
            redraw(Prompt, Left, Right),
            raw_loop(Prompt, Left, Right, History, 0, <<>>)
    end.

reverse_search_accept(Prompt, History, Selected) ->
    case history_blank(Selected) of
        true ->
            redraw(Prompt, [], []),
            raw_loop(Prompt, [], [], History, 0, <<>>);
        false ->
            {L, R} = bin_to_buffer(Selected),
            redraw(Prompt, L, R),
            raw_loop(Prompt, L, R, History, 0, <<>>)
    end.

reverse_search_loop(All, Query, Filtered, Cursor0) ->
    Cursor = clamp_cursor(Cursor0, length(Filtered)),
    draw_search_ui(Query, Filtered, Cursor),
    case read_key() of
        eof ->
            eof;
        {error, _} ->
            eof;
        enter ->
            pick_filtered(Filtered, Cursor);
        tab ->
            pick_filtered(Filtered, Cursor);
        esc ->
            cancel;
        ctrl_c ->
            cancel;
        ctrl_g ->
            cancel;
        up ->
            reverse_search_loop(All, Query, Filtered, max(0, Cursor - 1));
        ctrl_p ->
            reverse_search_loop(All, Query, Filtered, max(0, Cursor - 1));
        down ->
            reverse_search_loop(
                All, Query, Filtered, min(length(Filtered) - 1, Cursor + 1)
            );
        ctrl_n ->
            reverse_search_loop(
                All, Query, Filtered, min(length(Filtered) - 1, Cursor + 1)
            );
        backspace ->
            NewQuery =
                case Query of
                    [] -> [];
                    [_ | _] -> lists:droplast(Query)
                end,
            NewFiltered = history_search_filter(All, NewQuery),
            reverse_search_loop(All, NewQuery, NewFiltered, 0);
        delete ->
            reverse_search_loop(All, Query, Filtered, Cursor);
        {char, C} when is_integer(C), C >= 32, C =/= 127 ->
            NewQuery = Query ++ [C],
            NewFiltered = history_search_filter(All, NewQuery),
            reverse_search_loop(All, NewQuery, NewFiltered, 0);
        _ ->
            reverse_search_loop(All, Query, Filtered, Cursor)
    end.

pick_filtered([], _Cursor) ->
    cancel;
pick_filtered(Filtered, Cursor) when Cursor >= 0, Cursor < length(Filtered) ->
    Cmd = lists:nth(Cursor + 1, Filtered),
    Bin =
        case Cmd of
            B when is_binary(B) -> B;
            L when is_list(L) -> unicode:characters_to_binary(L);
            _ -> <<>>
        end,
    {ok, Bin};
pick_filtered(_, _) ->
    cancel.

clamp_cursor(_C, 0) ->
    0;
clamp_cursor(C, _Len) when C < 0 ->
    0;
clamp_cursor(C, Len) when C >= Len ->
    Len - 1;
clamp_cursor(C, _Len) ->
    C.

enter_alt_screen() ->
    io:put_chars("\e[?1049h\e[H\e[2J").

leave_alt_screen() ->
    io:put_chars("\e[?1049l").

draw_search_ui(Query, Filtered, Cursor) ->
    %% Full repaint from home — alternate screen, so wipe + rewrite is fine.
    io:put_chars("\e[H\e[J"),
    QueryLine = search_query_line(Query),
    io:put_chars([QueryLine, "\r\n"]),
    Len = length(Filtered),
    Start =
        case Cursor >= ?SEARCH_MAX_ROWS of
            true -> Cursor - ?SEARCH_MAX_ROWS + 1;
            false -> 0
        end,
    End = min(Start + ?SEARCH_MAX_ROWS, Len),
    draw_search_rows(Filtered, Start, End, Cursor),
    Footer = search_footer(Len),
    io:put_chars(Footer),
    %% Park the cursor at the end of the query line.
    Col = 2 + length(Query),
    io:put_chars(["\e[H", "\e[", integer_to_list(Col + 1), $G]).

search_query_line([]) ->
    case get(gleshell_color) of
        false ->
            "> search history...";
        _ ->
            ["> ", "\e[2m", "search history...", "\e[0m"]
    end;
search_query_line(Query) when is_list(Query) ->
    ["> ", Query].

draw_search_rows(_Filtered, Start, End, _Cursor) when Start >= End ->
    ok;
draw_search_rows(Filtered, Start, End, Cursor) ->
    draw_search_rows_loop(Filtered, Start, End, Cursor).

draw_search_rows_loop(_Filtered, I, End, _Cursor) when I >= End ->
    ok;
draw_search_rows_loop(Filtered, I, End, Cursor) ->
    Cmd0 = lists:nth(I + 1, Filtered),
    CmdList =
        case Cmd0 of
            Bin when is_binary(Bin) ->
                case unicode:characters_to_list(Bin) of
                    L when is_list(L) -> L;
                    _ -> []
                end;
            L when is_list(L) -> L;
            _ -> []
        end,
    %% Flatten newlines so a multi-line history entry stays one row.
    Line = [case C of $\n -> $\s; $\r -> $\s; _ -> C end || C <- CmdList],
    case I =:= Cursor of
        true ->
            case get(gleshell_color) of
                false ->
                    io:put_chars(["  ", Line, "\r\n"]);
                _ ->
                    %% Bold blue — stinkpot styleCursor (lipgloss color "4").
                    io:put_chars(["  ", "\e[1;34m", Line, "\e[0m", "\r\n"])
            end;
        false ->
            io:put_chars(["  ", Line, "\r\n"])
    end,
    draw_search_rows_loop(Filtered, I + 1, End, Cursor).

search_footer(N) ->
    %% Unicode arrows match stinkpot's footer copy.
    Text = [
        "  ",
        integer_to_list(N),
        " matches · ↑/↓ move · enter accept · esc cancel"
    ],
    case get(gleshell_color) of
        false ->
            Text;
        _ ->
            ["\e[2m", Text, "\e[0m"]
    end.

%% Dedupe history preserving newest-first order (stinkpot stores unique cmds).
uniq_history(Hist) when is_list(Hist) ->
    uniq_history(Hist, #{}, []);
uniq_history(_) ->
    [].

uniq_history([], _Seen, Acc) ->
    lists:reverse(Acc);
uniq_history([H | T], Seen, Acc) ->
    Key =
        case H of
            B when is_binary(B) -> B;
            L when is_list(L) -> unicode:characters_to_binary(L);
            _ -> <<>>
        end,
    case history_blank(Key) orelse maps:is_key(Key, Seen) of
        true ->
            uniq_history(T, Seen, Acc);
        false ->
            uniq_history(T, Seen#{Key => true}, [Key | Acc])
    end.

%% Test helper / filter: history (newest first binaries) + query → filtered list.
-spec history_search(list(binary()), binary()) -> list(binary()).
history_search(History, Query) when is_list(History), is_binary(Query) ->
    QList =
        case unicode:characters_to_list(Query) of
            L when is_list(L) -> L;
            _ -> []
        end,
    history_search_filter(uniq_history(History), QList);
history_search(_, _) ->
    [].

%% Empty / whitespace-only query → all candidates (newest first).
%% Otherwise fuzzy subsequence match (case-insensitive), best scores first;
%% ties keep newest-first order via stable index.
history_search_filter(Candidates, Query) when is_list(Candidates), is_list(Query) ->
    case string:trim(Query) of
        [] ->
            Candidates;
        QTrim ->
            QLower = to_lower_chars(QTrim),
            Scored = score_candidates(Candidates, QLower, 0, []),
            Sorted = lists:sort(
                fun({Sa, Ia, _}, {Sb, Ib, _}) ->
                    case Sa =:= Sb of
                        true -> Ia =< Ib;
                        false -> Sa > Sb
                    end
                end,
                Scored
            ),
            [Cmd || {_S, _I, Cmd} <- Sorted]
    end;
history_search_filter(_, _) ->
    [].

score_candidates([], _Q, _I, Acc) ->
    Acc;
score_candidates([Cmd | Rest], Q, I, Acc) ->
    CmdList =
        case Cmd of
            Bin when is_binary(Bin) ->
                case unicode:characters_to_list(Bin) of
                    L when is_list(L) -> L;
                    _ -> []
                end;
            L when is_list(L) -> L;
            _ -> []
        end,
    case fuzzy_score(Q, to_lower_chars(CmdList)) of
        nomatch ->
            score_candidates(Rest, Q, I + 1, Acc);
        Score when is_integer(Score) ->
            score_candidates(Rest, Q, I + 1, [{Score, I, Cmd} | Acc])
    end.

%% Case-insensitive subsequence fuzzy score (inspired by sahilm/fuzzy used by
%% stinkpot). Higher is better. Consecutive matches and early matches score up.
fuzzy_score([], _Cand) ->
    0;
fuzzy_score(Query, Cand) ->
    fuzzy_score(Query, Cand, 0, 0, -2, 0).

fuzzy_score([], _Cand, Score, _Idx, _Last, _Run) ->
    Score;
fuzzy_score([_ | _], [], _Score, _Idx, _Last, _Run) ->
    nomatch;
fuzzy_score([Q | Qs], [C | Cs], Score, Idx, Last, Run) when Q =:= C ->
    Consecutive =
        case Idx =:= Last + 1 of
            true -> Run + 1;
            false -> 0
        end,
    %% Base hit + bonus for runs; slight preference for earlier positions.
    Bonus = Consecutive * 4,
    Early = max(0, 32 - Idx),
    fuzzy_score(Qs, Cs, Score + 16 + Bonus + Early, Idx + 1, Idx, Consecutive);
fuzzy_score(Q, [_ | Cs], Score, Idx, Last, _Run) ->
    fuzzy_score(Q, Cs, Score, Idx + 1, Last, 0).

to_lower_chars(List) when is_list(List) ->
    [
        case C of
            X when is_integer(X), X >= $A, X =< $Z -> X + 32;
            X -> X
        end
     || C <- List
    ];
to_lower_chars(_) ->
    [].

kill_word([]) ->
    {[], []};
kill_word(Left) ->
    %% Left is reversed: strip trailing spaces then a word.
    L1 = drop_while_space(Left),
    drop_while_word(L1).

drop_while_space([C | Rest]) when C =:= $\s; C =:= $\t ->
    drop_while_space(Rest);
drop_while_space(L) ->
    L.

drop_while_word([]) ->
    {[], []};
drop_while_word([C | Rest]) when C =:= $\s; C =:= $\t ->
    {[C | Rest], []};
drop_while_word([_ | Rest]) ->
    drop_while_word(Rest).

redraw(Prompt, Left, Right) ->
    Full = lists:reverse(Left) ++ Right,
    FullBin =
        case unicode:characters_to_binary(Full) of
            Bin when is_binary(Bin) -> Bin;
            _ -> <<>>
        end,
    Colored = highlight_line(FullBin),
    %% Fish/Nu-style ghost text: grey suffix of the newest history match.
    %% Only when the cursor is at end of the buffer (Right == []).
    HintChars =
        case Right of
            [] -> history_hint_suffix(Full);
            _ -> []
        end,
    HintPainted = paint_history_hint(HintChars),
    HintBin =
        case unicode:characters_to_binary(HintChars) of
            HB when is_binary(HB) -> HB;
            _ -> <<>>
        end,
    %% Clear every physical row the previous render occupied. A longer history
    %% entry can soft-wrap; `\e[2K` alone only erases the current row, so a
    %% shorter recall (or empty draft) used to leave a blank-looking row and
    %% stale wrap residue that felt like an empty ↑ slot.
    clear_input_rows(),
    io:put_chars([Prompt, Colored, HintPainted]),
    %% Include hint width so multi-line wrap clears correctly on next redraw.
    Rows = count_input_rows(Prompt, <<FullBin/binary, HintBin/binary>>),
    put(gleshell_input_rows, Rows),
    %% Cursor sits after typed text, before the grey hint (and before Right).
    CursorBack = length(HintChars) + length(Right),
    case CursorBack of
        0 ->
            ok;
        N ->
            %% Best-effort: codepoint count ≈ columns for ASCII-heavy input.
            io:put_chars(["\e[", integer_to_list(N), $D])
    end.

%% Accept the full greyed-out history suggestion into the buffer.
accept_history_hint(Prompt, Left, Right, History, HistPos, Saved) ->
    case Right of
        [] ->
            case history_hint_suffix(lists:reverse(Left)) of
                [] ->
                    raw_loop(Prompt, Left, Right, History, HistPos, Saved);
                Suffix ->
                    %% Left is reversed; append Suffix at end of buffer.
                    NewLeft = lists:reverse(Suffix) ++ Left,
                    redraw(Prompt, NewLeft, []),
                    raw_loop(Prompt, NewLeft, [], History, 0, <<>>)
            end;
        _ ->
            raw_loop(Prompt, Left, Right, History, HistPos, Saved)
    end.

%% Accept the next word of the history suggestion (leading space + word).
accept_history_hint_word(Prompt, Left, Right, History, HistPos, Saved) ->
    case Right of
        [] ->
            case history_hint_suffix(lists:reverse(Left)) of
                [] ->
                    raw_loop(Prompt, Left, Right, History, HistPos, Saved);
                Suffix ->
                    Word = take_hint_word(Suffix),
                    case Word of
                        [] ->
                            raw_loop(Prompt, Left, Right, History, HistPos, Saved);
                        _ ->
                            NewLeft = lists:reverse(Word) ++ Left,
                            redraw(Prompt, NewLeft, []),
                            raw_loop(Prompt, NewLeft, [], History, 0, <<>>)
                    end
            end;
        _ ->
            raw_loop(Prompt, Left, Right, History, HistPos, Saved)
    end.

%% First token of a hint: optional leading whitespace + following non-space run.
take_hint_word([]) ->
    [];
take_hint_word([C | Rest]) when C =:= $\s; C =:= $\t ->
    [C | take_hint_nonspace(Rest)];
take_hint_word(Rest) ->
    take_hint_nonspace(Rest).

take_hint_nonspace([]) ->
    [];
take_hint_nonspace([C | _Rest]) when C =:= $\s; C =:= $\t ->
    [];
take_hint_nonspace([C | Rest]) ->
    [C | take_hint_nonspace(Rest)].

%% Newest-first history: suffix of the first entry that has Buffer as a proper prefix.
history_hint_suffix([]) ->
    [];
history_hint_suffix(Buffer) when is_list(Buffer) ->
    Hist =
        case get(gleshell_history) of
            L when is_list(L) -> L;
            _ -> []
        end,
    history_hint_suffix(Hist, Buffer).

history_hint_suffix([], _Buffer) ->
    [];
%% Empty buffer: never ghost the whole previous command (Nu default).
history_hint_suffix(_History, []) ->
    [];
history_hint_suffix([H | T], Buffer) ->
    HList =
        case H of
            Bin when is_binary(Bin) -> unicode:characters_to_list(Bin);
            List when is_list(List) -> List;
            _ -> []
        end,
    case is_list(HList) andalso lists:prefix(Buffer, HList) of
        true when length(HList) > length(Buffer) ->
            lists:nthtail(length(Buffer), HList);
        _ ->
            history_hint_suffix(T, Buffer)
    end.

paint_history_hint([]) ->
    [];
paint_history_hint(Chars) ->
    case get(gleshell_color) of
        false ->
            Chars;
        _ ->
            %% Dark gray — same as Nu `color_config.hints` / shape_nothing.
            ["\e[90m", Chars, "\e[0m"]
    end.

%% Test helper: given history (newest first) and buffer, return grey suffix binary.
-spec history_hint(list(binary()), binary()) -> binary().
history_hint(History, Buffer) when is_list(History), is_binary(Buffer) ->
    BufList =
        case unicode:characters_to_list(Buffer) of
            L when is_list(L) -> L;
            _ -> []
        end,
    case history_hint_suffix(History, BufList) of
        [] ->
            <<>>;
        Suffix ->
            case unicode:characters_to_binary(Suffix) of
                Bin when is_binary(Bin) -> Bin;
                _ -> <<>>
            end
    end.

%% Move to the start of the previous input block and erase its rows.
clear_input_rows() ->
    Rows0 =
        case get(gleshell_input_rows) of
            N when is_integer(N), N > 0 -> N;
            _ -> 1
        end,
    %% Cap so a bad columns() estimate cannot wipe the path line above the prompt.
    Rows = min(Rows0, 16),
    %% Cursor sits on the last physical row of the previous draw when Right=[].
    case Rows of
        1 ->
            io:put_chars([$\r, "\e[2K"]);
        _ ->
            Up = Rows - 1,
            io:put_chars([$\r, "\e[", integer_to_list(Up), $A, "\e[J"])
    end.

%% How many terminal rows does prompt+line occupy (ANSI-aware, 1-col glyphs).
count_input_rows(Prompt, FullBin) ->
    Cols =
        case io:columns() of
            {ok, C} when is_integer(C), C >= 8 -> C;
            {ok, C} when is_integer(C), C > 0 -> 8;
            _ -> 80
        end,
    PW = visible_width(Prompt),
    FW = visible_width(FullBin),
    Total = PW + FW,
    case Total =< 0 of
        true -> 1;
        false -> min(16, (Total + Cols - 1) div Cols)
    end.

%% Visible column count ignoring CSI (ESC [ … final). Wide glyphs count as 1
%% (same approximation as the pager); good enough to clear wrap residue.
visible_width(Data) when is_binary(Data) ->
    visible_width(unicode:characters_to_list(Data));
visible_width(List) when is_list(List) ->
    visible_width_loop(List, 0, normal);
visible_width(_) ->
    0.

visible_width_loop([], Acc, _) ->
    Acc;
visible_width_loop([16#1b | Rest], Acc, normal) ->
    visible_width_loop(Rest, Acc, esc);
visible_width_loop([_C | Rest], Acc, normal) ->
    visible_width_loop(Rest, Acc + 1, normal);
visible_width_loop([$[ | Rest], Acc, esc) ->
    visible_width_loop(Rest, Acc, csi);
visible_width_loop([_ | Rest], Acc, esc) ->
    visible_width_loop(Rest, Acc, normal);
visible_width_loop([C | Rest], Acc, csi) when C >= 16#40, C =< 16#7e ->
    visible_width_loop(Rest, Acc, normal);
visible_width_loop([_ | Rest], Acc, csi) ->
    visible_width_loop(Rest, Acc, csi).

highlight_line(Bin) when is_binary(Bin) ->
    case get(gleshell_color) of
        false ->
            Bin;
        _ ->
            try
                case 'gleshell@highlight':line(Bin) of
                    Out when is_binary(Out) -> Out;
                    Out when is_list(Out) -> unicode:characters_to_binary(Out);
                    _ -> Bin
                end
            catch
                _:_ ->
                    Bin
            end
    end.

buffer_to_bin(Left, Right) ->
    unicode:characters_to_binary(lists:reverse(Left) ++ Right).

bin_to_buffer(Bin) when is_binary(Bin) ->
    Chars = unicode:characters_to_list(Bin),
    {lists:reverse(Chars), []};
bin_to_buffer(List) when is_list(List) ->
    {lists:reverse(List), []}.

%% ---------------------------------------------------------------------------
%% Key reading (raw mode — keys arrive as soon as pressed)
%% ---------------------------------------------------------------------------

read_key() ->
    case io:get_chars("", 1) of
        eof ->
            eof;
        {error, Reason} ->
            {error, Reason};
        <<C/utf8>> ->
            decode_key(C, <<>>);
        [C] when is_integer(C) ->
            decode_key(C, <<>>);
        Bin when is_binary(Bin), byte_size(Bin) > 0 ->
            case unicode:characters_to_list(Bin) of
                [C | _] -> decode_key(C, <<>>);
                _ -> read_key()
            end;
        List when is_list(List), List =/= [] ->
            decode_key(hd(List), <<>>);
        _ ->
            read_key()
    end.

decode_key($\r, _) -> enter;
decode_key($\n, _) -> enter;
decode_key($\t, _) -> tab;
decode_key(127, _) -> backspace;
decode_key($\b, _) -> backspace;
decode_key(1, _) -> ctrl_a;
decode_key(5, _) -> ctrl_e;
decode_key(4, _) -> ctrl_d;
decode_key(3, _) -> ctrl_c;
decode_key(11, _) -> ctrl_k;
decode_key(21, _) -> ctrl_u;
decode_key(23, _) -> ctrl_w;
decode_key(12, _) -> ctrl_l;
decode_key(18, _) -> ctrl_r;
decode_key(6, _) -> ctrl_f;
decode_key(16, _) -> ctrl_p;
decode_key(14, _) -> ctrl_n;
decode_key(7, _) -> ctrl_g;
decode_key(?ESC, _) ->
    read_escape();
decode_key(C, _) when is_integer(C), C >= 32 ->
    {char, C};
decode_key(_, _) ->
    other.

read_escape() ->
    case io:get_chars("", 1) of
        eof ->
            %% Lone ESC (no follow-up) — treat as Escape.
            esc;
        <<?ESC>> ->
            %% ESC ESC
            esc;
        <<"[">> ->
            read_csi();
        <<$O>> ->
            %% SS3 sequences: OH = home, OF = end, OA/OB/OC/OD arrows
            case io:get_chars("", 1) of
                <<"A">> -> up;
                <<"B">> -> down;
                <<"C">> -> right;
                <<"D">> -> left;
                <<"H">> -> home;
                <<"F">> -> 'end';
                _ -> other
            end;
        %% Alt+letter arrives as ESC then the letter (meta).
        <<$f>> ->
            alt_f;
        <<$F>> ->
            alt_f;
        _ ->
            %% Unknown ESC sequence — Escape is the usual cancel key in TUIs.
            esc
    end.

read_csi() ->
    read_csi_params([]).

read_csi_params(Acc) ->
    case io:get_chars("", 1) of
        eof ->
            other;
        <<C/utf8>> when C >= $0, C =< $9 ->
            read_csi_params([C | Acc]);
        <<$;>> ->
            read_csi_params([$; | Acc]);
        <<$~>> ->
            Params = lists:reverse(Acc),
            case Params of
                "1" -> home;
                "3" -> delete;
                "4" -> 'end';
                "5" -> page_up;
                "6" -> page_down;
                "7" -> home;
                "8" -> 'end';
                _ -> other
            end;
        <<"A">> ->
            up;
        <<"B">> ->
            down;
        <<"C">> ->
            right;
        <<"D">> ->
            left;
        <<"H">> ->
            home;
        <<"F">> ->
            'end';
        _ ->
            other
    end.

%% ---------------------------------------------------------------------------
%% History persistence
%% ---------------------------------------------------------------------------

history_file() ->
    case application:get_env(kernel, shell_history_path) of
        {ok, Path} when is_list(Path) ->
            filename:join(Path, "lines");
        {ok, Path} when is_binary(Path) ->
            filename:join(unicode:characters_to_list(Path), "lines");
        _ ->
            filename:join(
                filename:basedir(user_cache, "gleshell-history"), "lines"
            )
    end.

load_line_history() ->
    File = history_file(),
    case file:read_file(File) of
        {ok, Bin} ->
            Lines0 = [
                string:trim(L, trailing, [$\r])
             || L <- binary:split(Bin, <<"\n">>, [global])
            ],
            %% Newest first; sanitize drops blanks / ANSI-only / ZWSP-only.
            put(gleshell_history, sanitize_history(lists:reverse(Lines0)));
        _ ->
            put(gleshell_history, [])
    end,
    put(gleshell_color, true),
    ok.

save_line_history() ->
    case get(gleshell_history) of
        Hist when is_list(Hist) ->
            File = history_file(),
            _ = filelib:ensure_dir(File),
            %% Store oldest-first for human readability; drop blanks.
            Kept = lists:sublist(sanitize_history(Hist), ?HISTORY_MAX),
            Body = [[L, $\n] || L <- lists:reverse(Kept)],
            _ = file:write_file(File, Body),
            ok;
        _ ->
            ok
    end.

%% Drop blank entries; keep order (newest first).
sanitize_history(Hist) when is_list(Hist) ->
    [L || L <- Hist, not history_blank(L)];
sanitize_history(_) ->
    [].

%% Empty / whitespace-only / ANSI-only / zero-width-only lines look blank when
%% recalled with ↑ — never store or navigate to them.
history_blank(Bin) when is_binary(Bin) ->
    history_blank_visible(string:trim(Bin));
history_blank(List) when is_list(List) ->
    case unicode:characters_to_binary(List) of
        Bin when is_binary(Bin) ->
            history_blank_visible(string:trim(Bin));
        _ ->
            true
    end;
history_blank(_) ->
    true.

history_blank_visible(Bin) when is_binary(Bin) ->
    case strip_ansi_bin(Bin) of
        <<>> ->
            true;
        Visible ->
            case unicode:characters_to_list(Visible) of
                List when is_list(List), List =/= [] ->
                    %% ZWSP / ZWNJ / ZWJ / BOM / soft hyphen — render as empty.
                    lists:all(
                        fun(C) ->
                            C =:= 16#200B orelse C =:= 16#200C orelse
                                C =:= 16#200D orelse C =:= 16#FEFF orelse
                                C =:= 16#00AD
                        end,
                        List
                    );
                _ ->
                    false
            end
    end.

%% Strip CSI sequences (ESC [ … final) for blank detection.
strip_ansi_bin(Bin) when is_binary(Bin) ->
    case unicode:characters_to_list(Bin) of
        List when is_list(List) ->
            unicode:characters_to_binary(strip_ansi_list(List, normal, []));
        _ ->
            Bin
    end.

strip_ansi_list([], _State, Acc) ->
    lists:reverse(Acc);
strip_ansi_list([16#1b | Rest], normal, Acc) ->
    strip_ansi_list(Rest, esc, Acc);
strip_ansi_list([C | Rest], normal, Acc) ->
    strip_ansi_list(Rest, normal, [C | Acc]);
strip_ansi_list([$[ | Rest], esc, Acc) ->
    strip_ansi_list(Rest, csi, Acc);
strip_ansi_list([_ | Rest], esc, Acc) ->
    strip_ansi_list(Rest, normal, Acc);
strip_ansi_list([C | Rest], csi, Acc) when C >= 16#40, C =< 16#7e ->
    strip_ansi_list(Rest, normal, Acc);
strip_ansi_list([_ | Rest], csi, Acc) ->
    strip_ansi_list(Rest, csi, Acc).

push_history(Line) when is_binary(Line) ->
    %% Trim so "  ls  " does not become a near-blank distinct from "ls".
    Trimmed = string:trim(Line),
    case history_blank(Trimmed) of
        true ->
            ok;
        false ->
            Hist = sanitize_history(
                case get(gleshell_history) of
                    L when is_list(L) -> L;
                    _ -> []
                end
            ),
            New = case Hist of
                [Trimmed | _] -> Hist;
                _ -> [Trimmed | Hist]
            end,
            put(gleshell_history, lists:sublist(New, ?HISTORY_MAX)),
            ok
    end;
push_history(_) ->
    ok.

%% ---------------------------------------------------------------------------
%% OS / process helpers
%% ---------------------------------------------------------------------------

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

%% All process environment variables as a list of {Name, Value} binaries.
-spec list_env() -> list({binary(), binary()}).
list_env() ->
    lists:map(
        fun(Entry) ->
            case string:split(Entry, "=", leading) of
                [K, V] ->
                    {unicode:characters_to_binary(K), unicode:characters_to_binary(V)};
                [K] ->
                    {unicode:characters_to_binary(K), <<>>};
                _ ->
                    {<<>>, <<>>}
            end
        end,
        os:getenv()
    ).

%% Substring/regex search helper for the `find` builtin.
%% Returns {ok, true|false} or {error, Message} on invalid pattern.
-spec re_contains(binary(), binary(), boolean()) -> {ok, boolean()} | {error, binary()}.
re_contains(Text, Pattern, IgnoreCase)
  when is_binary(Text), is_binary(Pattern), is_boolean(IgnoreCase) ->
    Opts0 = [unicode],
    Opts =
        case IgnoreCase of
            true ->
                [caseless | Opts0];
            false ->
                Opts0
        end,
    case re:compile(Pattern, Opts) of
        {ok, Re} ->
            case re:run(Text, Re, [{capture, none}]) of
                match ->
                    {ok, true};
                nomatch ->
                    {ok, false}
            end;
        {error, {Reason, _}} ->
            {error, iolist_to_binary(io_lib:format("~p", [Reason]))};
        {error, Reason} ->
            {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.

-spec which(binary()) -> {ok, binary()} | {error, nil}.
which(Command) when is_binary(Command) ->
    case which_all(Command) of
        [Path | _] ->
            {ok, Path};
        [] ->
            {error, nil}
    end.

%% All matching executables on PATH (or the path itself if absolute/relative).
%% Order matches PATH search; duplicates from the same resolved path are dropped.
-spec which_all(binary()) -> [binary()].
which_all(Command) when is_binary(Command) ->
    Cmd = unicode:characters_to_list(Command),
    case Cmd of
        [] ->
            [];
        _ ->
            case has_path_sep(Cmd) of
                true ->
                    case is_executable_file(Cmd) of
                        true ->
                            [unicode:characters_to_binary(filename:absname(Cmd))];
                        false ->
                            []
                    end;
                false ->
                    case os:getenv("PATH") of
                        false ->
                            [];
                        PathStr ->
                            Dirs = string:tokens(PathStr, path_sep()),
                            find_all_in_path(Cmd, Dirs, #{}, [])
                    end
            end
    end.

path_sep() ->
    case os:type() of
        {win32, _} -> ";";
        _ -> ":"
    end.

has_path_sep(Cmd) ->
    lists:member($/, Cmd) orelse lists:member($\\, Cmd).

find_all_in_path(_Cmd, [], _Seen, Acc) ->
    lists:reverse(Acc);
find_all_in_path(Cmd, [Dir | Rest], Seen, Acc) ->
    File = filename:join(Dir, Cmd),
    case is_executable_file(File) of
        true ->
            Abs = filename:absname(File),
            Bin = unicode:characters_to_binary(Abs),
            case maps:is_key(Abs, Seen) of
                true ->
                    find_all_in_path(Cmd, Rest, Seen, Acc);
                false ->
                    find_all_in_path(Cmd, Rest, Seen#{Abs => true}, [Bin | Acc])
            end;
        false ->
            find_all_in_path(Cmd, Rest, Seen, Acc)
    end.

is_executable_file(Path) ->
    case file:read_file_info(Path) of
        {ok, #file_info{type = regular, mode = Mode}} ->
            %% Any execute bit (owner/group/other).
            (Mode band 8#111) =/= 0;
        _ ->
            false
    end.

%% Canonical absolute path: resolve `.`/`..` and follow symlinks (like realpath(3)).
%% On failure (missing path, loop, etc.) returns {error, nil}.
-spec realpath(binary()) -> {ok, binary()} | {error, nil}.
realpath(Path) when is_binary(Path) ->
    case realpath_loop(unicode:characters_to_list(Path), #{}) of
        {ok, Resolved} ->
            {ok, unicode:characters_to_binary(Resolved)};
        {error, _} ->
            {error, nil}
    end.

realpath_loop(Path, Seen) ->
    Abs = filename:absname(Path),
    case maps:is_key(Abs, Seen) of
        true ->
            {error, eloop};
        false ->
            case file:read_link(Abs) of
                {ok, Target} ->
                    Next =
                        case filename:pathtype(Target) of
                            absolute ->
                                Target;
                            _ ->
                                filename:absname(filename:join(filename:dirname(Abs), Target))
                        end,
                    realpath_loop(Next, Seen#{Abs => true});
                {error, einval} ->
                    %% Not a symlink — Abs is the final path.
                    case file:read_file_info(Abs) of
                        {ok, _} ->
                            {ok, Abs};
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end
    end.

-spec home_dir() -> {ok, binary()} | {error, binary()}.
home_dir() ->
    case os:getenv("HOME") of
        false ->
            {error, <<"HOME not set">>};
        Home ->
            {ok, unicode:characters_to_binary(Home)}
    end.

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

%% ---------------------------------------------------------------------------
%% External commands
%%
%% Two modes:
%%
%% 1. `run_cmd/2` — capture stdout/stderr into a binary (pipelines, `let x =`,
%%    non-TTY display). Prefers a throwaway PTY when color is wanted so tools
%%    emit ANSI for `cmd | less`; falls back to pipes.
%%
%% 2. `run_cmd_tty/2` — foreground interactive. Prefer util-linux `script`
%%    (PTY + key relay via `io:get_chars`) so Ctrl+C can SIGINT the child.
%%    `erl_child_setup` calls setsid, so the child is never in the terminal's
%%    foreground process group — kernel SIGINT goes to BEAM, not the child.
%%    Fallback: inherit real stdio (`nouse_stdio`) when script/TTY is missing.
%%
%% Auth tools (`sudo`, `run0`, …) also need a controlling TTY; the PTY path
%% covers that. Host termios during children: cooked for OPOST/ONLCR (no
%% staircase) but ISIG off so Ctrl+C is readable as byte 3 instead of opening
%% the Erlang BREAK menu.
%% ---------------------------------------------------------------------------

-spec run_cmd(binary(), [binary()], binary()) ->
    {ok, {integer(), binary()}} | {error, binary()}.
run_cmd(Command, Args, Stdin) when is_binary(Command), is_list(Args), is_binary(Stdin) ->
    case resolve_cmd(Command, Args) of
        {error, _} = E ->
            E;
        {ok, Path, PortArgs} ->
            try
                run_cmd_capture(Path, PortArgs, Stdin)
            catch
                _:Reason ->
                    {error, reason_to_bin(Reason)}
            end
    end.

%% Foreground interactive: inherit TTY when possible.
%% Non-empty Stdin is still fed (temp file + redirect) so `cat f | less` works.
%%
%% While the REPL uses OTP `{noshell, raw}`, prim_tty leaves termios with
%% OPOST/ONLCR off so a bare LF does not return the cursor to column 0.
%% Tools that write LF-only lines (fastfetch, many TUIs) look staircased if
%% they inherit that TTY. Wrap inherit/PTY runs in cooked mode and restore
%% raw afterwards (same idea as println/1 converting to CRLF for shell text).
-spec run_cmd_tty(binary(), [binary()], binary()) ->
    {ok, {integer(), binary()}} | {error, binary()}.
run_cmd_tty(Command, Args, Stdin) when is_binary(Command), is_list(Args), is_binary(Stdin) ->
    case resolve_cmd(Command, Args) of
        {error, _} = E ->
            E;
        {ok, Path, PortArgs} ->
            try
                case stdout_isatty() of
                    false ->
                        run_cmd_capture(Path, PortArgs, Stdin);
                    true ->
                        with_cooked_tty(fun() ->
                            %% PTY for all interactive when possible: key relay
                            %% sees Ctrl+C and can SIGINT the child process group.
                            case {os:find_executable("script"), find_tty_path()} of
                                {Script, {ok, Tty}} when is_list(Script) ->
                                    run_cmd_pty(Script, Path, PortArgs, Tty, Stdin);
                                _ ->
                                    run_cmd_inherit(Path, PortArgs, Stdin)
                            end
                        end)
                end
            catch
                _:Reason ->
                    {error, reason_to_bin(Reason)}
            end
    end.

%% Temporarily put the controlling TTY into cooked output + non-canonical
%% input for an external child, then restore previous termios (raw REPL).
%%
%% Applied whenever stdout is a TTY (not only raw REPL): -c under a terminal
%% still needs -isig/-icanon so Ctrl+C is a readable byte for the interrupt
%% path. No-op when stty/TTY is unavailable.
with_cooked_tty(Fun) when is_function(Fun, 0) ->
    case stdout_isatty() of
        false ->
            Fun();
        true ->
            case stty_save() of
                undefined ->
                    %% Still try to apply host flags; restore is best-effort.
                    stty_sane(),
                    try
                        Fun()
                    after
                        ok
                    end;
                Saved ->
                    stty_sane(),
                    try
                        Fun()
                    after
                        stty_restore(Saved)
                    end
            end
    end.

stty_save() ->
    case stty_run(["-g"]) of
        {ok, Out} ->
            case string:trim(Out, both, [$\s, $\t, $\n, $\r]) of
                "" ->
                    undefined;
                Settings ->
                    %% stty -g is a single token of colon-separated hex flags.
                    Settings
            end;
        _ ->
            undefined
    end.

stty_sane() ->
    %% Host TTY while an external runs under the raw REPL:
    %% - sane / opost / onlcr: LF→CRLF so children don't staircase
    %% - -isig: Ctrl+C is byte 3 (not kernel SIGINT → BEAM BREAK menu)
    %% - -icanon min 1 time 0: deliver each byte immediately — with ICANON
    %%   left on, Ctrl+C sits in the line buffer until Enter and our key
    %%   relay never sees it (external freezes; second ^C looks wedged)
    %% - -echo: host must not echo keys we relay into the child PTY
    _ = stty_run([
        "sane",
        "-isig",
        "-icanon",
        "min",
        "1",
        "time",
        "0",
        "-echo"
    ]),
    ok.

stty_restore(Settings) when is_list(Settings) ->
    _ = stty_run([Settings]),
    ok;
stty_restore(_) ->
    ok.

%% Run stty against the real terminal device (not a pipe). Prefer the pts
%% path from /proc (same as sudo/PTY path), then `/dev/tty`.
%%
%% NOTE: do not use filelib:is_file/1 for `/dev/tty` — it is a device node,
%% so is_file returns false and would skip stty entirely (fastfetch staircase).
stty_run(Args) when is_list(Args) ->
    case os:find_executable("stty") of
        false ->
            {error, no_stty};
        Stty when is_list(Stty) ->
            stty_run_on(Stty, Args, stty_devices())
    end.

stty_devices() ->
    case find_tty_path() of
        {ok, Path} ->
            %% Prefer the concrete pts; /dev/tty is a fallback alias.
            [Path, "/dev/tty"];
        _ ->
            ["/dev/tty"]
    end.

stty_run_on(_Stty, _Args, []) ->
    {error, no_tty};
stty_run_on(Stty, Args, [Dev | Rest]) ->
    case stty_on_device(Stty, Dev, Args) of
        {ok, _} = Ok ->
            Ok;
        _ ->
            stty_run_on(Stty, Args, Rest)
    end.

stty_on_device(Stty, Dev, Args) when is_list(Stty), is_list(Dev), is_list(Args) ->
    try
        Port = open_port(
            {spawn_executable, Stty},
            [
                binary,
                exit_status,
                use_stdio,
                stderr_to_stdout,
                {args, ["-F", Dev | Args]}
            ]
        ),
        %% No interrupt watch — internal helper, must not steal TTY input.
        case collect_output_quiet(Port, <<>>, 5000) of
            {ok, {0, Bin}} ->
                {ok, unicode:characters_to_list(Bin)};
            {ok, {Status, Bin}} ->
                {error, {Status, Bin}};
            {error, _} = E ->
                E
        end
    catch
        _:_ ->
            {error, stty_failed}
    end.

resolve_cmd(Command, Args) ->
    case os:find_executable(unicode:characters_to_list(Command)) of
        false ->
            {error, <<"command not found: ", Command/binary>>};
        Path ->
            PortArgs = [unicode:characters_to_list(A) || A <- Args],
            {ok, Path, PortArgs}
    end.

%% Capture mode: collect stdout/stderr into a binary (pipelines, `let x =`).
%%
%% When the shell wants color, prefer a throwaway PTY (`script`) so tools that
%% only colorize on a TTY (`jj`, `git`, …) still emit ANSI for `cmd | less` —
%% without tool-specific env hacks. Nested pagers are forced to `cat` so the
%% child cannot hang waiting for interactive `less`. Falls back to plain pipes
%% (+ FORCE_COLOR / git overlays) when `script` is missing.
%%
%% Stdin is redirected via temp file / `$GLESHELL_STDIN` so programs never hang
%% on an open-but-never-written Erlang port pipe.
run_cmd_capture(Path, PortArgs, Stdin) when is_binary(Stdin) ->
    case want_child_color() of
        true ->
            case os:find_executable("script") of
                Script when is_list(Script) ->
                    run_cmd_capture_pty(Script, Path, PortArgs, Stdin);
                _ ->
                    run_cmd_capture_pipe(Path, PortArgs, Stdin)
            end;
        false ->
            run_cmd_capture_pipe(Path, PortArgs, Stdin)
    end.

run_cmd_capture_pipe(Path, PortArgs, Stdin) when is_binary(Stdin) ->
    with_stdin_file(Stdin, fun(StdinPath) ->
        sh_exec(Path, PortArgs, StdinPath, capture)
    end).

%% PTY capture: child sees a TTY (colors, auto decorations) but we only collect
%% output — nothing is relayed to the user's terminal.
run_cmd_capture_pty(Script, Path, PortArgs, <<>>) ->
    run_cmd_capture_pty_argv(Script, [Path | PortArgs]);
run_cmd_capture_pty(Script, Path, PortArgs, Stdin) when is_binary(Stdin) ->
    with_stdin_file(Stdin, fun(StdinPath) ->
        with_exec_runner(Path, PortArgs, StdinPath, fun(Runner) ->
            run_cmd_capture_pty_argv(Script, [Runner])
        end)
    end).

run_cmd_capture_pty_argv(Script, Argv) when is_list(Argv) ->
    with_trapped_exits(fun() ->
        Port = open_port(
            {spawn_executable, Script},
            [
                binary,
                exit_status,
                stderr_to_stdout,
                use_stdio,
                stream,
                {env, child_env_capture_pty()},
                {args, ["-q", "-e", "/dev/null", "--" | Argv]}
            ]
        ),
        put(gleshell_output_shown, false),
        try
            case collect_output(Port, <<>>) of
                {ok, {Status, Acc}} ->
                    {ok, {Status, normalize_pty_output(Acc)}};
                Other ->
                    Other
            end
        after
            catch port_close(Port)
        end
    end).

%% Inherit real stdio — pagers/editors talk to the terminal directly.
%% LESS=FRX (via child_env) lets less pass ANSI colors from jj/git.
%%
%% Empty stdin: pure inherit (bare `less` reads the TTY).
%% Non-empty stdin: still inherit stdout/stderr TTY, but redirect stdin from
%% a temp file so `cat file | less` pages the pipeline data.
%%
%% Ctrl+C: prefer the PTY path (key relay). Inherit is a fallback when
%% `script` is missing — host is -isig/-icanon so Ctrl+C is byte 3; a
%% watcher SIGINTs the child's process group (setsid means kernel SIGINT
%% never reaches the child even with ISIG on).
run_cmd_inherit(Path, PortArgs, Stdin) when is_binary(Stdin) ->
    case Stdin of
        <<>> ->
            Port = open_port(
                {spawn_executable, Path},
                [
                    exit_status,
                    nouse_stdio,
                    {env, child_env()},
                    {args, PortArgs}
                ]
            ),
            put(gleshell_output_shown, true),
            await_port_exit_interruptible(Port);
        _ ->
            with_stdin_file(Stdin, fun(StdinPath) ->
                sh_exec(Path, PortArgs, StdinPath, inherit)
            end)
    end.

%% PTY + key relay (interactive TTY, sudo/run0, …).
%%
%% util-linux `script` does NOT exec the argv after `--` directly. It runs
%% `$SHELL -c "<joined args>"` (see script(1)). Nested
%% `sh -c 'exec "$0" …' path` therefore becomes one mangled shell string and
%% the real binary never runs (fastfetch → empty output, exit 0).
%%
%% Empty stdin: pass Path/args through as simple tokens (`script -- cmd args`).
%% Non-empty stdin (pipeline → less): write a one-shot runner script that
%% redirects and execs, then `script -- /tmp/runner` (single path token).
run_cmd_pty(Script, Path, PortArgs, TtyPath, <<>>) ->
    run_cmd_pty_argv(Script, [Path | PortArgs], TtyPath, Path, PortArgs, <<>>);
run_cmd_pty(Script, Path, PortArgs, TtyPath, Stdin) when is_binary(Stdin) ->
    with_stdin_file(Stdin, fun(StdinPath) ->
        with_exec_runner(Path, PortArgs, StdinPath, fun(Runner) ->
            run_cmd_pty_argv(Script, [Runner], TtyPath, Path, PortArgs, Stdin)
        end)
    end).

run_cmd_pty_argv(Script, Argv, TtyPath, Path, PortArgs, Stdin) when is_list(Argv) ->
    with_trapped_exits(fun() ->
        Port = open_port(
            {spawn_executable, Script},
            [
                binary,
                exit_status,
                stderr_to_stdout,
                use_stdio,
                stream,
                {env, child_env()},
                {args, ["-q", "-e", "/dev/null", "--" | Argv]}
            ]
        ),
        case file:open(TtyPath, [write, raw, binary]) of
            {ok, TtyOut} ->
                GL = group_leader(),
                Reader = spawn(fun() ->
                    group_leader(GL, self()),
                    io_to_port(Port)
                end),
                put(gleshell_output_shown, true),
                try
                    collect_output_relay(Port, TtyOut, <<>>)
                after
                    exit(Reader, kill),
                    catch file:close(TtyOut),
                    catch port_close(Port)
                end;
            {error, _} ->
                catch port_close(Port),
                put(gleshell_output_shown, false),
                run_cmd_inherit(Path, PortArgs, Stdin)
        end
    end).

%% One-shot `#!/bin/sh` runner: exec Path with PortArgs, stdin from StdinPath.
%% Needed because `script` flattens argv into `$SHELL -c` (no real multi-arg exec).
with_exec_runner(Path, PortArgs, StdinPath, Fun) when is_function(Fun, 1) ->
    case write_runner_script(Path, PortArgs, StdinPath) of
        {ok, Runner} ->
            try
                Fun(Runner)
            after
                _ = file:delete(Runner)
            end;
        {error, Reason} ->
            {error, reason_to_bin({runner_script, Reason})}
    end.

write_runner_script(Path, PortArgs, StdinPath) ->
    Dir =
        case os:getenv("TMPDIR") of
            false ->
                "/tmp";
            "" ->
                "/tmp";
            D ->
                D
        end,
    Name =
        filename:join(
            Dir,
            "gleshell-run-" ++ integer_to_list(erlang:unique_integer([positive]))
        ),
    Body = runner_script_body(Path, PortArgs, StdinPath),
    case file:write_file(Name, Body) of
        ok ->
            case file:change_mode(Name, 8#755) of
                ok ->
                    {ok, Name};
                {error, _} = E ->
                    _ = file:delete(Name),
                    E
            end;
        {error, _} = E ->
            E
    end.

runner_script_body(Path, PortArgs, StdinPath) ->
    ArgsQ = [[$\s, shell_single_quote(A)] || A <- PortArgs],
    [
        "#!/bin/sh\n",
        "exec ",
        shell_single_quote(Path),
        ArgsQ,
        " < ",
        shell_single_quote(StdinPath),
        "\n"
    ].

%% Safe single-quoted shell token (`foo'bar` → `'foo'\''bar'`).
shell_single_quote(S) when is_list(S) ->
    [$' | shell_single_quote_chars(S) ++ "'"];
shell_single_quote(B) when is_binary(B) ->
    shell_single_quote(unicode:characters_to_list(B)).

shell_single_quote_chars([]) ->
    [];
shell_single_quote_chars([$' | Rest]) ->
    "'\\''" ++ shell_single_quote_chars(Rest);
shell_single_quote_chars([C | Rest]) ->
    [C | shell_single_quote_chars(Rest)].

find_sh() ->
    case os:find_executable("sh") of
        false ->
            "/bin/sh";
        S ->
            S
    end.

%% Run Path with stdin redirected from StdinPath.
%% Mode `capture` uses pipes; `inherit` uses nouse_stdio (real TTY for out/err).
sh_exec(Path, PortArgs, StdinPath, capture) ->
    Port = open_port(
        {spawn_executable, find_sh()},
        [
            binary,
            exit_status,
            stderr_to_stdout,
            use_stdio,
            stream,
            {env, [{"GLESHELL_STDIN", StdinPath} | child_env()]},
            {args, ["-c", "exec \"$0\" \"$@\" < \"$GLESHELL_STDIN\"", Path | PortArgs]}
        ]
    ),
    put(gleshell_output_shown, false),
    collect_output(Port, <<>>);
sh_exec(Path, PortArgs, StdinPath, inherit) ->
    Port = open_port(
        {spawn_executable, find_sh()},
        [
            exit_status,
            nouse_stdio,
            {env, [{"GLESHELL_STDIN", StdinPath} | child_env()]},
            {args, ["-c", "exec \"$0\" \"$@\" < \"$GLESHELL_STDIN\"", Path | PortArgs]}
        ]
    ),
    put(gleshell_output_shown, true),
    await_port_exit_interruptible(Port).

%% Provide a filesystem path for stdin bytes; clean up temp files afterwards.
with_stdin_file(<<>>, Fun) when is_function(Fun, 1) ->
    Fun("/dev/null");
with_stdin_file(Data, Fun) when is_binary(Data), is_function(Fun, 1) ->
    case write_stdin_tmp(Data) of
        {ok, Path} ->
            try
                Fun(Path)
            after
                _ = file:delete(Path)
            end;
        {error, Reason} ->
            {error, reason_to_bin({stdin_tmp, Reason})}
    end.

write_stdin_tmp(Data) when is_binary(Data) ->
    Dir =
        case os:getenv("TMPDIR") of
            false ->
                "/tmp";
            "" ->
                "/tmp";
            D ->
                D
        end,
    Name =
        filename:join(
            Dir,
            "gleshell-stdin-" ++ integer_to_list(erlang:unique_integer([positive]))
        ),
    case file:write_file(Name, Data) of
        ok ->
            {ok, Name};
        {error, _} = E ->
            E
    end.

%% Relay keypresses from the group leader to the child's PTY (script stdin).
%% Ctrl+C (ETX / byte 3): SIGINT the child process group, and still write the
%% byte so the PTY line discipline can deliver SIGINT on the slave side too.
io_to_port(Port) ->
    case io:get_chars("", 1) of
        eof ->
            ok;
        {error, _} ->
            ok;
        Data ->
            case io_data_to_bin(Data) of
                <<>> ->
                    io_to_port(Port);
                <<3>> = Bin ->
                    signal_port_group(Port, int),
                    catch port_command(Port, Bin),
                    io_to_port(Port);
                Bin ->
                    catch port_command(Port, Bin),
                    io_to_port(Port)
            end
    end.

io_data_to_bin(Bin) when is_binary(Bin) ->
    Bin;
io_data_to_bin([C]) when is_integer(C), C >= 0, C =< 16#7F ->
    <<C>>;
io_data_to_bin(List) when is_list(List) ->
    case unicode:characters_to_binary(List) of
        Bin when is_binary(Bin) ->
            Bin;
        _ ->
            <<>>
    end;
io_data_to_bin(_) ->
    <<>>.

%% When a port's OS process is killed (Ctrl+C → SIGINT), the linked port may
%% exit with `epipe` / signal reasons. Without trap_exit the shell process
%% dies with "Erlang exit: Epipe" instead of returning to the prompt.
with_trapped_exits(Fun) when is_function(Fun, 0) ->
    Old = process_flag(trap_exit, true),
    try
        Fun()
    after
        process_flag(trap_exit, Old),
        drain_exit_msgs()
    end.

drain_exit_msgs() ->
    receive
        {'EXIT', _, _} ->
            drain_exit_msgs()
    after 0 ->
        ok
    end.

%% Inherit path: watch for Ctrl+C (byte 3) and SIGINT the child group.
%% Used when `script`/PTY is unavailable; same kill path as the PTY relay.
await_port_exit_interruptible(Port) ->
    with_trapped_exits(fun() ->
        with_interrupt_watch(Port, fun() ->
            await_port_exit_interruptible_loop(Port)
        end)
    end).

await_port_exit_interruptible_loop(Port) ->
    receive
        {Port, {exit_status, Status}} ->
            {ok, {Status, <<>>}};
        {'EXIT', Port, _Reason} ->
            {ok, {130, <<>>}};
        {gleshell_interrupt, _} ->
            signal_port_group(Port, int),
            await_port_exit_after_interrupt(Port, 2000)
    end.

await_port_exit_after_interrupt(Port, GraceMs) ->
    receive
        {Port, {exit_status, Status}} ->
            {ok, {Status, <<>>}};
        {'EXIT', Port, _Reason} ->
            {ok, {130, <<>>}};
        {gleshell_interrupt, _} ->
            signal_port_group(Port, kill),
            await_port_exit_after_interrupt(Port, 1000)
    after GraceMs ->
        signal_port_group(Port, kill),
        catch port_close(Port),
        receive
            {Port, {exit_status, Status}} ->
                {ok, {Status, <<>>}};
            {'EXIT', Port, _} ->
                {ok, {130, <<>>}}
        after 1000 ->
            {ok, {130, <<>>}}
        end
    end.

collect_output(Port, Acc) ->
    with_trapped_exits(fun() ->
        with_interrupt_watch(Port, fun() ->
            collect_output_loop(Port, Acc, 120_000)
        end)
    end).

collect_output_loop(Port, Acc, Timeout) ->
    receive
        {Port, {data, Data}} when is_binary(Data) ->
            collect_output_loop(Port, <<Acc/binary, Data/binary>>, Timeout);
        {Port, {data, Data}} when is_list(Data) ->
            Bin = unicode:characters_to_binary(Data),
            collect_output_loop(Port, <<Acc/binary, Bin/binary>>, Timeout);
        {Port, {exit_status, Status}} ->
            {ok, {Status, Acc}};
        {'EXIT', Port, _Reason} ->
            {ok, {130, Acc}};
        {gleshell_interrupt, _} ->
            signal_port_group(Port, int),
            collect_output_after_interrupt(Port, Acc, 2000)
    after Timeout ->
        signal_port_group(Port, term),
        catch port_close(Port),
        {error, <<"command timed out after 120s">>}
    end.

collect_output_after_interrupt(Port, Acc, GraceMs) ->
    receive
        {Port, {data, Data}} when is_binary(Data) ->
            collect_output_after_interrupt(
                Port, <<Acc/binary, Data/binary>>, GraceMs
            );
        {Port, {data, Data}} when is_list(Data) ->
            Bin = unicode:characters_to_binary(Data),
            collect_output_after_interrupt(
                Port, <<Acc/binary, Bin/binary>>, GraceMs
            );
        {Port, {exit_status, Status}} ->
            {ok, {Status, Acc}};
        {'EXIT', Port, _Reason} ->
            {ok, {130, Acc}};
        {gleshell_interrupt, _} ->
            signal_port_group(Port, kill),
            collect_output_after_interrupt(Port, Acc, 1000)
    after GraceMs ->
        signal_port_group(Port, kill),
        catch port_close(Port),
        receive
            {Port, {data, Data}} when is_binary(Data) ->
                collect_output_after_interrupt(
                    Port, <<Acc/binary, Data/binary>>, 500
                );
            {Port, {data, Data}} when is_list(Data) ->
                Bin = unicode:characters_to_binary(Data),
                collect_output_after_interrupt(
                    Port, <<Acc/binary, Bin/binary>>, 500
                );
            {Port, {exit_status, Status}} ->
                {ok, {Status, Acc}};
            {'EXIT', Port, _} ->
                {ok, {130, Acc}}
        after 1000 ->
            {ok, {130, Acc}}
        end
    end.

%% PTY session: no timeout (password prompts, long pagers, etc.).
%% Ctrl+C is handled in io_to_port/1 (SIGINT); also accept interrupt msgs.
%% Caller must run under with_trapped_exits/1 so port epipe is not fatal.
collect_output_relay(Port, Tty, Acc) ->
    receive
        {Port, {data, Data}} when is_binary(Data) ->
            _ = file:write(Tty, Data),
            collect_output_relay(Port, Tty, <<Acc/binary, Data/binary>>);
        {Port, {data, Data}} when is_list(Data) ->
            Bin = unicode:characters_to_binary(Data),
            _ = file:write(Tty, Bin),
            collect_output_relay(Port, Tty, <<Acc/binary, Bin/binary>>);
        {Port, {exit_status, Status}} ->
            {ok, {Status, normalize_pty_output(Acc)}};
        {'EXIT', Port, _Reason} ->
            {ok, {130, normalize_pty_output(Acc)}};
        {gleshell_interrupt, _} ->
            signal_port_group(Port, int),
            collect_output_relay_after_interrupt(Port, Tty, Acc, 2000)
    end.

collect_output_relay_after_interrupt(Port, Tty, Acc, GraceMs) ->
    receive
        {Port, {data, Data}} when is_binary(Data) ->
            _ = file:write(Tty, Data),
            collect_output_relay_after_interrupt(
                Port, Tty, <<Acc/binary, Data/binary>>, GraceMs
            );
        {Port, {data, Data}} when is_list(Data) ->
            Bin = unicode:characters_to_binary(Data),
            _ = file:write(Tty, Bin),
            collect_output_relay_after_interrupt(
                Port, Tty, <<Acc/binary, Bin/binary>>, GraceMs
            );
        {Port, {exit_status, Status}} ->
            {ok, {Status, normalize_pty_output(Acc)}};
        {'EXIT', Port, _Reason} ->
            {ok, {130, normalize_pty_output(Acc)}};
        {gleshell_interrupt, _} ->
            signal_port_group(Port, kill),
            collect_output_relay_after_interrupt(Port, Tty, Acc, 1000)
    after GraceMs ->
        signal_port_group(Port, kill),
        catch port_close(Port),
        receive
            {Port, {exit_status, Status}} ->
                {ok, {Status, normalize_pty_output(Acc)}};
            {'EXIT', Port, _} ->
                {ok, {130, normalize_pty_output(Acc)}}
        after 1000 ->
            {ok, {130, normalize_pty_output(Acc)}}
        end
    end.

%% ---------------------------------------------------------------------------
%% Ctrl+C / SIGINT forwarding
%%
%% BEAM's open_port → erl_child_setup → setsid, so the child is not in the
%% terminal foreground group. Host ISIG is left off while a child runs; we
%% watch for byte 3 (ETX) and kill(-pid, SIGINT) on the child's process group.
%% ---------------------------------------------------------------------------

with_interrupt_watch(_Port, Fun) when is_function(Fun, 0) ->
    Parent = self(),
    GL = group_leader(),
    Watcher =
        case can_watch_interrupt() of
            true ->
                spawn(fun() ->
                    group_leader(GL, self()),
                    interrupt_watch_loop(Parent)
                end);
            false ->
                undefined
        end,
    try
        Fun()
    after
        case Watcher of
            undefined ->
                ok;
            W ->
                exit(W, kill),
                drain_interrupt_msgs()
        end
    end.

%% Collect port output without Ctrl+C watching (stty and other helpers).
collect_output_quiet(Port, Acc, Timeout) ->
    receive
        {Port, {data, Data}} when is_binary(Data) ->
            collect_output_quiet(Port, <<Acc/binary, Data/binary>>, Timeout);
        {Port, {data, Data}} when is_list(Data) ->
            Bin = unicode:characters_to_binary(Data),
            collect_output_quiet(Port, <<Acc/binary, Bin/binary>>, Timeout);
        {Port, {exit_status, Status}} ->
            {ok, {Status, Acc}}
    after Timeout ->
        catch port_close(Port),
        {error, <<"command timed out">>}
    end.

%% Watch when the REPL owns the TTY (raw mode) or stdin is a terminal.
can_watch_interrupt() ->
    case get(gleshell_raw) of
        true ->
            true;
        _ ->
            stdout_isatty()
    end.

interrupt_watch_loop(Parent) when is_pid(Parent) ->
    case catch io:get_chars("", 1) of
        eof ->
            ok;
        {error, _} ->
            ok;
        {'EXIT', _} ->
            ok;
        Data ->
            case io_data_to_bin(Data) of
                <<3>> ->
                    Parent ! {gleshell_interrupt, self()},
                    interrupt_watch_loop(Parent);
                _ ->
                    %% Non-Ctrl+C: discard here (capture mode). Interactive
                    %% PTY uses io_to_port instead; inherit prefers PTY.
                    interrupt_watch_loop(Parent)
            end
    end.

drain_interrupt_msgs() ->
    receive
        {gleshell_interrupt, _} ->
            drain_interrupt_msgs()
    after 0 ->
        ok
    end.

%% SIGINT/SIGTERM/SIGKILL the port's OS process group (setsid → pgid = pid).
signal_port_group(Port, Sig) when is_port(Port) ->
    case erlang:port_info(Port, os_pid) of
        {os_pid, Pid} when is_integer(Pid), Pid > 0 ->
            kill_os_group(Pid, Sig);
        _ ->
            ok
    end.

kill_os_group(Pid, Sig) when is_integer(Pid) ->
    Kill =
        case os:find_executable("kill") of
            false ->
                "kill";
            K ->
                K
        end,
    SigArg =
        case Sig of
            int ->
                "-INT";
            term ->
                "-TERM";
            kill ->
                "-KILL"
        end,
    %% Negative pid → process group (child is session/group leader after setsid).
    Pg = "-" ++ integer_to_list(Pid),
    Single = integer_to_list(Pid),
    _ = kill_once(Kill, [SigArg, Pg]),
    _ = kill_once(Kill, [SigArg, Single]),
    ok.

kill_once(Kill, Args) ->
    try
        Port = open_port(
            {spawn_executable, Kill},
            [exit_status, nouse_stdio, {args, Args}]
        ),
        receive
            {Port, {exit_status, _}} ->
                ok
        after 1000 ->
            catch port_close(Port),
            ok
        end
    catch
        _:_ ->
            ok
    end.

%% PTY line discipline often emits CR-LF; normalize to LF for structured use.
normalize_pty_output(Bin) when is_binary(Bin) ->
    binary:replace(Bin, <<"\r\n">>, <<"\n">>, [global]).

%% Extra env for external commands (merged into the process environment).
%%
%% - SHELL=/bin/sh: `script` invokes $SHELL; nu/fish break `script -c`.
%% - LESS=FRX when unset: external pagers pass through ANSI (-R) and exit on
%%   short output (-F) without clearing the screen (-X).
%% - When the shell wants color and the child has no real TTY (pipe capture
%%   fallback): FORCE_COLOR / CLICOLOR_FORCE, plus git GIT_CONFIG_* overlays
%%   (git ignores FORCE_COLOR; decorate=auto drops ref names on pipes).
%%   Prefer PTY capture (`child_env_capture_pty`) so jj/git/etc. colorize
%%   naturally for `cmd | less` without per-tool config.
child_env() ->
    Env0 = child_env_base(),
    case want_child_color() of
        false ->
            Env0;
        true ->
            force_git_tty_env(force_color_env(Env0))
    end.

%% PTY capture env: color via TTY detection; never nest an interactive pager.
child_env_capture_pty() ->
    disable_nested_pagers(force_color_env(child_env_base())).

child_env_base() ->
    Env0 = [{"SHELL", "/bin/sh"}],
    case os:getenv("LESS") of
        false ->
            [{"LESS", "FRX"} | Env0];
        "" ->
            [{"LESS", "FRX"} | Env0];
        _ ->
            Env0
    end.

%% FORCE_COLOR / CLICOLOR_FORCE for children that honor them.
force_color_env(Env) ->
    Env1 =
        case os:getenv("FORCE_COLOR") of
            false ->
                [{"FORCE_COLOR", "1"} | Env];
            "0" ->
                Env;
            _ ->
                Env
        end,
    case os:getenv("CLICOLOR_FORCE") of
        false ->
            [{"CLICOLOR_FORCE", "1"} | Env1];
        "0" ->
            Env1;
        _ ->
            Env1
    end.

%% Capture must not hang inside the child's own pager (git/jj → less).
%% Always override for PTY capture; interactive `run_cmd_tty` uses child_env/0.
disable_nested_pagers(Env) ->
    [
        {"PAGER", "cat"},
        {"GIT_PAGER", "cat"},
        {"JJ_PAGER", "cat"},
        {"SYSTEMD_PAGER", "cat"},
        {"MANPAGER", "cat"}
        | Env
    ].

%% Pipe-capture fallback only (git ≥ 2.31 GIT_CONFIG_*). Skipped when the
%% caller already set GIT_CONFIG_COUNT so we do not clobber.
%%
%% - color.ui=always: git ignores FORCE_COLOR
%% - log.decorate=short: default auto hides decorations on non-TTY stdout
force_git_tty_env(Env) ->
    case os:getenv("GIT_CONFIG_COUNT") of
        false ->
            [
                {"GIT_CONFIG_COUNT", "2"},
                {"GIT_CONFIG_KEY_0", "color.ui"},
                {"GIT_CONFIG_VALUE_0", "always"},
                {"GIT_CONFIG_KEY_1", "log.decorate"},
                {"GIT_CONFIG_VALUE_1", "short"}
                | Env
            ];
        _ ->
            Env
    end.

%% Match gleshell color policy: off under NO_COLOR; otherwise on for a TTY
%% or when the parent already forces color.
want_child_color() ->
    case os:getenv("NO_COLOR") of
        L when is_list(L), L =/= "" ->
            false;
        _ ->
            case stdout_isatty() of
                true ->
                    true;
                false ->
                    force_color_set()
            end
    end.

force_color_set() ->
    case os:getenv("FORCE_COLOR") of
        L when is_list(L), L =/= "", L =/= "0" ->
            true;
        _ ->
            case os:getenv("CLICOLOR_FORCE") of
                L when is_list(L), L =/= "", L =/= "0" ->
                    true;
                _ ->
                    false
            end
    end.

%% True when the last external command already streamed output to the TTY
%% (PTY relay). Cleared after being read so the REPL does not double-print.
-spec take_output_shown() -> boolean().
take_output_shown() ->
    case erase(gleshell_output_shown) of
        true -> true;
        _ -> false
    end.

-spec clear_output_shown() -> nil.
clear_output_shown() ->
    erase(gleshell_output_shown),
    nil.

%% Find a terminal device attached to this BEAM (or an ancestor).
%% Note: os:getpid() returns a string, not an integer.
find_tty_path() ->
    case catch list_to_integer(os:getpid()) of
        Pid when is_integer(Pid) ->
            case tty_path_for_pid(Pid) of
                {ok, _} = Ok ->
                    Ok;
                error ->
                    walk_parent_tty(Pid, 12)
            end;
        _ ->
            error
    end.

walk_parent_tty(_Pid, 0) ->
    error;
walk_parent_tty(Pid, N) when is_integer(Pid), Pid > 1 ->
    case parent_pid(Pid) of
        {ok, Parent} when Parent > 1, Parent =/= Pid ->
            case tty_path_for_pid(Parent) of
                {ok, _} = Ok ->
                    Ok;
                error ->
                    walk_parent_tty(Parent, N - 1)
            end;
        _ ->
            error
    end;
walk_parent_tty(_, _) ->
    error.

tty_path_for_pid(Pid) when is_integer(Pid) ->
    case read_tty_nr(Pid) of
        {ok, 0} ->
            error;
        {ok, TtyNr} ->
            tty_nr_to_path(TtyNr);
        error ->
            error
    end.

read_tty_nr(Pid) when is_integer(Pid) ->
    case file:read_file("/proc/" ++ integer_to_list(Pid) ++ "/stat") of
        {ok, Bin} ->
            case parse_stat_tty_nr(binary_to_list(Bin)) of
                {ok, N} -> {ok, N};
                error -> error
            end;
        _ ->
            error
    end.
%% /proc/pid/stat: "pid (comm) state ppid pgrp session tty_nr ..."
parse_stat_tty_nr(List) ->
    case lists:splitwith(fun(C) -> C =/= $) end, List) of
        {_, [$) | Rest0]} ->
            Rest = string:trim(Rest0, leading),
            Fields = string:tokens(Rest, " "),
            %% After ')': state, ppid, pgrp, session, tty_nr → index 5
            case length(Fields) >= 5 of
                true ->
                    try
                        {ok, list_to_integer(lists:nth(5, Fields))}
                    catch
                        _:_ -> error
                    end;
                false ->
                    error
            end;
        _ ->
            error
    end.

parent_pid(Pid) ->
    case file:read_file("/proc/" ++ integer_to_list(Pid) ++ "/stat") of
        {ok, Bin} ->
            case parse_stat_ppid(binary_to_list(Bin)) of
                {ok, P} -> {ok, P};
                error -> error
            end;
        _ ->
            error
    end.

parse_stat_ppid(List) ->
    case lists:splitwith(fun(C) -> C =/= $) end, List) of
        {_, [$) | Rest0]} ->
            Rest = string:trim(Rest0, leading),
            Fields = string:tokens(Rest, " "),
            %% After ')': state, ppid → index 2
            case length(Fields) >= 2 of
                true ->
                    try
                        {ok, list_to_integer(lists:nth(2, Fields))}
                    catch
                        _:_ -> error
                    end;
                false ->
                    error
            end;
        _ ->
            error
    end.

%% Decode Linux tty_nr (see drivers/tty/tty_io.c / procfs) to a device path.
tty_nr_to_path(0) ->
    error;
tty_nr_to_path(TtyNr) when is_integer(TtyNr) ->
    Major = (TtyNr bsr 8) band 16#ff,
    Minor = (TtyNr band 16#ff) bor (((TtyNr bsr 20) band 16#fff) bsl 8),
    Path =
        case Major of
            136 ->
                "/dev/pts/" ++ integer_to_list(Minor);
            4 when Minor >= 64 ->
                "/dev/ttyS" ++ integer_to_list(Minor - 64);
            4 ->
                "/dev/tty" ++ integer_to_list(Minor);
            _ ->
                undefined
        end,
    case Path of
        undefined ->
            error;
        _ ->
            case file:read_file_info(Path) of
                {ok, _} -> {ok, Path};
                _ -> error
            end
    end.

reason_to_bin(Reason) when is_atom(Reason) ->
    atom_to_binary(Reason, utf8);
reason_to_bin(Reason) when is_binary(Reason) ->
    Reason;
reason_to_bin(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).

%% ---------------------------------------------------------------------------
%% Current Unix epoch seconds (UTC). Used by the `now` builtin.
%% ---------------------------------------------------------------------------

-spec unix_now() -> integer().
unix_now() ->
    os:system_time(second).

%% ---------------------------------------------------------------------------
%% Format Unix epoch seconds as local calendar time:
%% "Jul 3 2026 9:39:40 PM" (abbreviated month, 12-hour clock).
%% Used for `ls` modified column display (data stays as raw Int).
%% ---------------------------------------------------------------------------

-spec format_unix_local(integer()) -> binary().
format_unix_local(Seconds) when is_integer(Seconds) ->
    try
        {{Y, Mo, D}, {H, Mi, S}} =
            calendar:system_time_to_local_time(Seconds, second),
        {H12, AmPm} = to_12h(H),
        iolist_to_binary(
            io_lib:format(
                "~s ~B ~4..0B ~B:~2..0B:~2..0B ~s",
                [month_abbr(Mo), D, Y, H12, Mi, S, AmPm]
            )
        )
    catch
        _:_ ->
            integer_to_binary(Seconds)
    end;
format_unix_local(_) ->
    <<"0">>.

%% 0 → 12 AM, 1–11 → AM, 12 → 12 PM, 13–23 → 1–11 PM
to_12h(0) -> {12, "AM"};
to_12h(H) when H < 12 -> {H, "AM"};
to_12h(12) -> {12, "PM"};
to_12h(H) -> {H - 12, "PM"}.

month_abbr(1) -> "Jan";
month_abbr(2) -> "Feb";
month_abbr(3) -> "Mar";
month_abbr(4) -> "Apr";
month_abbr(5) -> "May";
month_abbr(6) -> "Jun";
month_abbr(7) -> "Jul";
month_abbr(8) -> "Aug";
month_abbr(9) -> "Sep";
month_abbr(10) -> "Oct";
month_abbr(11) -> "Nov";
month_abbr(12) -> "Dec";
month_abbr(_) -> "???".

%% ---------------------------------------------------------------------------
%% ps: list system processes (Nushell-compatible columns, Linux /proc)
%% ---------------------------------------------------------------------------
%%
%% Returns a list of 17-tuples, one per process (numeric /proc entries that
%% can still be read after a short CPU sample interval):
%%
%%   {Pid, Ppid, Name, Status, Cpu, Mem, Virtual, Command, StartTime,
%%    UserId, ProcessGroupId, SessionId, Priority, ProcessThreads,
%%    Working, Paged, Cwd}
%%
%% Integers are bytes for mem/virtual/working/paged; StartTime is Unix
%% seconds (0 if unknown). Cpu is percent of one core over ~100ms, like Nu.
%%
-spec list_processes() ->
    list({
        integer(),
        integer(),
        binary(),
        binary(),
        float(),
        integer(),
        integer(),
        binary(),
        integer(),
        integer(),
        integer(),
        integer(),
        integer(),
        integer(),
        integer(),
        integer(),
        binary()
    }).
list_processes() ->
    case os:type() of
        {unix, linux} ->
            list_processes_linux();
        _ ->
            %% Other OSes: empty table rather than crash; caller still gets
            %% a valid table shape from the Gleam side when needed.
            []
    end.

list_processes_linux() ->
    Ticks = clk_tck(),
    PageSize = page_size(),
    Boot = boot_time_seconds(),
    Base = snapshot_cpu_times(),
    timer:sleep(100),
    IntervalMs = 100.0,
    case file:list_dir("/proc") of
        {ok, Entries} ->
            lists:filtermap(
                fun(Entry) ->
                    case is_pid_name(Entry) of
                        false ->
                            false;
                        true ->
                            Pid = list_to_integer(Entry),
                            case read_process(Pid, Ticks, PageSize, Boot, Base, IntervalMs) of
                                {ok, Row} ->
                                    {true, Row};
                                error ->
                                    false
                            end
                    end
                end,
                Entries
            );
        {error, _} ->
            []
    end.

is_pid_name([]) ->
    false;
is_pid_name(Name) ->
    lists:all(fun(C) -> C >= $0 andalso C =< $9 end, Name).

%% Map pid -> total jiffies (utime+stime) from first snapshot.
snapshot_cpu_times() ->
    case file:list_dir("/proc") of
        {ok, Entries} ->
            lists:foldl(
                fun(Entry, Acc) ->
                    case is_pid_name(Entry) of
                        false ->
                            Acc;
                        true ->
                            Pid = list_to_integer(Entry),
                            case read_stat_cpu(Pid) of
                                {ok, Total} ->
                                    Acc#{Pid => Total};
                                error ->
                                    Acc
                            end
                    end
                end,
                #{},
                Entries
            );
        {error, _} ->
            #{}
    end.

read_stat_cpu(Pid) ->
    case read_stat_fields(Pid) of
        {ok, Fields} ->
            U = maps:get(utime, Fields, 0),
            S = maps:get(stime, Fields, 0),
            {ok, U + S};
        error ->
            error
    end.

read_process(Pid, Ticks, PageSize, Boot, Base, IntervalMs) ->
    case read_stat_fields(Pid) of
        {ok, Fields} ->
            U = maps:get(utime, Fields, 0),
            S = maps:get(stime, Fields, 0),
            Total = U + S,
            Prev = maps:get(Pid, Base, Total),
            Delta = max(0, Total - Prev),
            %% usage_ms = delta_jiffies * 1000 / ticks; percent of one core
            UsageMs =
                case Ticks > 0 of
                    true ->
                        Delta * 1000 / Ticks;
                    false ->
                        0.0
                end,
            Cpu =
                case IntervalMs > 0.0 of
                    true ->
                        UsageMs * 100.0 / IntervalMs;
                    false ->
                        0.0
                end,
            Status = status_name(maps:get(state, Fields, $?)),
            Name = maps:get(comm, Fields, <<>>),
            Ppid = maps:get(ppid, Fields, 0),
            Pgrp = maps:get(pgrp, Fields, 0),
            Session = maps:get(session, Fields, 0),
            Priority = maps:get(priority, Fields, 0),
            Threads = maps:get(num_threads, Fields, 0),
            Vsize = maps:get(vsize, Fields, 0),
            RssPages = maps:get(rss, Fields, 0),
            MemFromStat = RssPages * PageSize,
            StartJiffies = maps:get(starttime, Fields, 0),
            StartTime =
                case Boot > 0 andalso Ticks > 0 of
                    true ->
                        Boot + StartJiffies div Ticks;
                    false ->
                        0
                end,
            {Mem, Working, Paged, Virtual, UserId} = read_status_mem(Pid, MemFromStat, Vsize),
            Command = read_cmdline(Pid, Name),
            Cwd = read_cwd(Pid),
            %% Gleam `ProcessInfo` constructor → Erlang `{process_info, ...}`.
            {ok,
                {process_info, Pid, Ppid, Name, Status, float(Cpu), Mem, Virtual,
                    Command, StartTime, UserId, Pgrp, Session, Priority, Threads,
                    Working, Paged, Cwd}};
        error ->
            error
    end.

%% Parse /proc/<pid>/stat. Comm is between the first '(' and the matching ") ".
read_stat_fields(Pid) ->
    Path = "/proc/" ++ integer_to_list(Pid) ++ "/stat",
    case file:read_file(Path) of
        {ok, Bin0} ->
            Bin = string:trim(Bin0, trailing, [$\n]),
            case binary:split(Bin, <<"(">>) of
                [_PidBin, Rest] ->
                    case binary:match(Rest, <<") ">>) of
                        {Pos, 2} ->
                            Comm = binary:part(Rest, 0, Pos),
                            After = binary:part(Rest, Pos + 2, byte_size(Rest) - Pos - 2),
                            Fs = binary:split(After, <<" ">>, [global]),
                            %% Indices after state (0-based): see proc(5)
                            %% 0 state, 1 ppid, 2 pgrp, 3 session,
                            %% 11 utime, 12 stime, 15 priority, 17 num_threads,
                            %% 19 starttime, 20 vsize, 21 rss
                            try
                                StateBin = nth_bin(Fs, 1),
                                State =
                                    case StateBin of
                                        <<C, _/binary>> ->
                                            C;
                                        <<>> ->
                                            $?;
                                        _ ->
                                            $?
                                    end,
                                {ok, #{
                                    comm => Comm,
                                    state => State,
                                    ppid => nth_int(Fs, 2),
                                    pgrp => nth_int(Fs, 3),
                                    session => nth_int(Fs, 4),
                                    utime => nth_int(Fs, 12),
                                    stime => nth_int(Fs, 13),
                                    priority => nth_int(Fs, 16),
                                    num_threads => nth_int(Fs, 18),
                                    starttime => nth_int(Fs, 20),
                                    vsize => nth_int(Fs, 21),
                                    rss => nth_int(Fs, 22)
                                }}
                            catch
                                _:_ ->
                                    error
                            end;
                        nomatch ->
                            error
                    end;
                _ ->
                    error
            end;
        {error, _} ->
            error
    end.

nth_bin(List, N) when N >= 1 ->
    case length(List) >= N of
        true ->
            lists:nth(N, List);
        false ->
            <<>>
    end.

nth_int(List, N) ->
    case nth_bin(List, N) of
        <<>> ->
            0;
        Bin ->
            try
                binary_to_integer(Bin)
            catch
                _:_ ->
                    0
            end
    end.

status_name($S) -> <<"Sleeping">>;
status_name($R) -> <<"Running">>;
status_name($D) -> <<"Disk sleep">>;
status_name($Z) -> <<"Zombie">>;
status_name($T) -> <<"Stopped">>;
status_name($t) -> <<"Tracing">>;
status_name($X) -> <<"Dead">>;
status_name($x) -> <<"Dead">>;
status_name($K) -> <<"Wakekill">>;
status_name($W) -> <<"Waking">>;
status_name($P) -> <<"Parked">>;
status_name($I) -> <<"Idle">>;
status_name(_) -> <<"Unknown">>.

%% Prefer VmRSS / VmSize / VmSwap (kB) and Uid from status; fall back to stat.
read_status_mem(Pid, MemFromStat, VsizeFromStat) ->
    Path = "/proc/" ++ integer_to_list(Pid) ++ "/status",
    case file:read_file(Path) of
        {ok, Bin} ->
            Lines = binary:split(Bin, <<"\n">>, [global]),
            Mem = kb_field(Lines, <<"VmRSS:">>, MemFromStat),
            Virtual = kb_field(Lines, <<"VmSize:">>, VsizeFromStat),
            Paged = kb_field(Lines, <<"VmSwap:">>, 0),
            UserId = uid_field(Lines),
            {Mem, Mem, Paged, Virtual, UserId};
        {error, _} ->
            {MemFromStat, MemFromStat, 0, VsizeFromStat, 0}
    end.

kb_field(Lines, Key, Default) ->
    case find_status_line(Lines, Key) of
        {ok, Rest} ->
            %% "   1234 kB"
            case re:run(Rest, <<"([0-9]+)">>, [{capture, all_but_first, binary}]) of
                {match, [Num]} ->
                    binary_to_integer(Num) * 1024;
                _ ->
                    Default
            end;
        error ->
            Default
    end.

uid_field(Lines) ->
    case find_status_line(Lines, <<"Uid:">>) of
        {ok, Rest} ->
            case re:run(Rest, <<"([0-9]+)">>, [{capture, all_but_first, binary}]) of
                {match, [Num]} ->
                    binary_to_integer(Num);
                _ ->
                    0
            end;
        error ->
            0
    end.

find_status_line([], _Key) ->
    error;
find_status_line([Line | Rest], Key) ->
    Klen = byte_size(Key),
    case Line of
        <<Key:Klen/binary, RestLine/binary>> ->
            {ok, RestLine};
        _ ->
            find_status_line(Rest, Key)
    end.

read_cmdline(Pid, FallbackName) ->
    Path = "/proc/" ++ integer_to_list(Pid) ++ "/cmdline",
    case file:read_file(Path) of
        {ok, <<>>} ->
            FallbackName;
        {ok, Bin} ->
            Parts = [P || P <- binary:split(Bin, <<0>>, [global]), P =/= <<>>],
            case Parts of
                [] ->
                    FallbackName;
                _ ->
                    Joined = iolist_to_binary(lists:join(<<" ">>, Parts)),
                    %% Nu collapses newlines/tabs in the display command.
                    re:replace(Joined, <<"[\n\t]">>, <<" ">>, [global, {return, binary}])
            end;
        {error, _} ->
            FallbackName
    end.

read_cwd(Pid) ->
    Path = "/proc/" ++ integer_to_list(Pid) ++ "/cwd",
    case file:read_link(Path) of
        {ok, Target} ->
            unicode:characters_to_binary(Target);
        {error, _} ->
            <<>>
    end.

clk_tck() ->
    case getconf_int("CLK_TCK") of
        {ok, N} when N > 0 ->
            N;
        _ ->
            100
    end.

page_size() ->
    case getconf_int("PAGE_SIZE") of
        {ok, N} when N > 0 ->
            N;
        _ ->
            4096
    end.

getconf_int(Name) ->
    Cmd = "getconf " ++ Name,
    try
        Out = string:trim(os:cmd(Cmd)),
        {ok, list_to_integer(Out)}
    catch
        _:_ ->
            error
    end.

boot_time_seconds() ->
    case file:read_file("/proc/stat") of
        {ok, Bin} ->
            case re:run(Bin, <<"btime ([0-9]+)">>, [{capture, all_but_first, binary}]) of
                {match, [Num]} ->
                    binary_to_integer(Num);
                _ ->
                    0
            end;
        {error, _} ->
            0
    end.

%% ---------------------------------------------------------------------------
%% whyport: sockets using a local/remote port (like `lsof -i :<port>`)
%% ---------------------------------------------------------------------------
%%
%% Returns a list of Gleam `PortSocket` records (Erlang tagged tuples):
%%
%%   {port_socket, Protocol, Family, LocalAddress, LocalPort,
%%    RemoteAddress, RemotePort, State, Pid, Name, Command, UserId, Fd}
%%
%% Protocol: <<"tcp">> | <<"udp">>
%% Family:   <<"ipv4">> | <<"ipv6">>
%% State:    LISTEN / ESTABLISHED / … (TCP) or empty for UDP
%% Pid/Fd:   0 when the owning process is unknown (permissions / TIME_WAIT)
%%
%% Linux only via /proc/net/{tcp,tcp6,udp,udp6} + /proc/*/fd socket inodes.
%%
-spec list_port_sockets(integer()) ->
    list({
        port_socket,
        binary(),
        binary(),
        binary(),
        integer(),
        binary(),
        integer(),
        binary(),
        integer(),
        binary(),
        binary(),
        integer(),
        integer()
    }).
list_port_sockets(Port) when is_integer(Port), Port >= 0, Port =< 65535 ->
    case os:type() of
        {unix, linux} ->
            list_port_sockets_linux(Port);
        _ ->
            []
    end;
list_port_sockets(_) ->
    [].

list_port_sockets_linux(Port) ->
    SockMap = socket_inode_map(),
    Sources = [
        {"/proc/net/tcp", <<"tcp">>, ipv4},
        {"/proc/net/tcp6", <<"tcp">>, ipv6},
        {"/proc/net/udp", <<"udp">>, ipv4},
        {"/proc/net/udp6", <<"udp">>, ipv6}
    ],
    lists:flatmap(
        fun({Path, Proto, Family}) ->
            parse_net_table(Path, Proto, Family, Port, SockMap)
        end,
        Sources
    ).

%% inode => list of {Pid, Fd, Name, Command}
socket_inode_map() ->
    case file:list_dir("/proc") of
        {ok, Entries} ->
            lists:foldl(
                fun(Entry, Acc) ->
                    case is_pid_name(Entry) of
                        false ->
                            Acc;
                        true ->
                            Pid = list_to_integer(Entry),
                            merge_pid_sockets(Pid, Acc)
                    end
                end,
                #{},
                Entries
            );
        {error, _} ->
            #{}
    end.

merge_pid_sockets(Pid, Acc) ->
    FdDir = "/proc/" ++ integer_to_list(Pid) ++ "/fd",
    case file:list_dir(FdDir) of
        {ok, Fds} ->
            {Name, Command} = pid_name_command(Pid),
            lists:foldl(
                fun(FdName, Acc1) ->
                    case is_pid_name(FdName) of
                        false ->
                            Acc1;
                        true ->
                            Fd = list_to_integer(FdName),
                            Link = FdDir ++ "/" ++ FdName,
                            case file:read_link(Link) of
                                {ok, Target} ->
                                    case socket_inode_from_link(Target) of
                                        {ok, Inode} ->
                                            Owner = {Pid, Fd, Name, Command},
                                            Prev = maps:get(Inode, Acc1, []),
                                            Acc1#{Inode => [Owner | Prev]};
                                        error ->
                                            Acc1
                                    end;
                                {error, _} ->
                                    Acc1
                            end
                    end
                end,
                Acc,
                Fds
            );
        {error, _} ->
            Acc
    end.

%% "socket:[12345]" or "socket:[12345]\n"
socket_inode_from_link(Target) when is_list(Target) ->
    socket_inode_from_link(unicode:characters_to_binary(Target));
socket_inode_from_link(Target) when is_binary(Target) ->
    case re:run(Target, <<"^socket:\\[([0-9]+)\\]">>, [{capture, all_but_first, binary}]) of
        {match, [Num]} ->
            {ok, binary_to_integer(Num)};
        _ ->
            error
    end;
socket_inode_from_link(_) ->
    error.

pid_name_command(Pid) ->
    case read_stat_fields(Pid) of
        {ok, Fields} ->
            Name = maps:get(comm, Fields, <<>>),
            {Name, read_cmdline(Pid, Name)};
        error ->
            {<<>>, <<>>}
    end.

parse_net_table(Path, Proto, Family, Port, SockMap) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            Lines = binary:split(Bin, <<"\n">>, [global]),
            %% First line is the header.
            case Lines of
                [_Header | Rows] ->
                    lists:flatmap(
                        fun(Line) ->
                            parse_net_row(Line, Proto, Family, Port, SockMap)
                        end,
                        Rows
                    );
                [] ->
                    []
            end;
        {error, _} ->
            []
    end.

parse_net_row(<<>>, _Proto, _Family, _Port, _SockMap) ->
    [];
parse_net_row(Line, Proto, Family, Port, SockMap) ->
    %% /proc/net/tcp columns (whitespace-separated after optional "sl:" index):
    %%   sl local_address rem_address st … uid timeout inode
    Parts = [P || P <- binary:split(string:trim(Line), <<" ">>, [global]), P =/= <<>>],
    case Parts of
        %% drop "0:" style index
        [_Sl, Local, Remote, St | Rest] when length(Rest) >= 6 ->
            %% uid is 7th field after sl (index 7 in 0-based after splitting with sl),
            %% inode is field 9 (0-based: parts after drop of sl: local=0 rem=1 st=2
            %% tx=3 rx=4 tr=5 tm=6 retrnsmt=7 uid=8 timeout=9 inode=10 — wait.
            %% With sl kept: [sl, local, rem, st, tx_rx, tr_tm, retrnsmt, uid, timeout, inode]
            %% Actually tx_queue:rx_queue is one token, tr:tm->when is one.
            %% Parts after split: sl, local, rem, st, tx:rx, tr:tm, retrnsmt, uid, timeout, inode, …
            case Rest of
                [_TxRx, _TrTm, _Retr, UidBin, _Timeout, InodeBin | _] ->
                    case {parse_addr_port(Local, Family), parse_addr_port(Remote, Family)} of
                        {{ok, LAddr, LPort}, {ok, RAddr, RPort}} ->
                            case LPort =:= Port orelse RPort =:= Port of
                                false ->
                                    [];
                                true ->
                                    State = tcp_state_name(Proto, St),
                                    Uid =
                                        try
                                            binary_to_integer(UidBin)
                                        catch
                                            _:_ ->
                                                0
                                        end,
                                    Inode =
                                        try
                                            binary_to_integer(InodeBin)
                                        catch
                                            _:_ ->
                                                0
                                        end,
                                    Owners = maps:get(Inode, SockMap, []),
                                    case Owners of
                                        [] ->
                                            [
                                                {port_socket, Proto, family_bin(Family), LAddr, LPort,
                                                    RAddr, RPort, State, 0, <<>>, <<>>, Uid, 0}
                                            ];
                                        _ ->
                                            [
                                                {port_socket, Proto, family_bin(Family), LAddr, LPort,
                                                    RAddr, RPort, State, Pid, Name, Command, Uid, Fd}
                                             || {Pid, Fd, Name, Command} <- lists:reverse(Owners)
                                            ]
                                    end
                            end;
                        _ ->
                            []
                    end;
                _ ->
                    []
            end;
        _ ->
            []
    end.

family_bin(ipv4) -> <<"ipv4">>;
family_bin(ipv6) -> <<"ipv6">>.

%% Local/remote address in /proc/net is HEXIP:HEXPORT (host byte order for port;
%% IP is little-endian 32-bit words).
parse_addr_port(Bin, Family) ->
    case binary:split(Bin, <<":">>) of
        [IpHex, PortHex] ->
            try
                Port = binary_to_integer(PortHex, 16),
                Addr = decode_ip(IpHex, Family),
                {ok, Addr, Port}
            catch
                _:_ ->
                    error
            end;
        _ ->
            error
    end.

decode_ip(Hex, ipv4) ->
    <<A, B, C, D>> = <<(binary_to_integer(Hex, 16)):32/little>>,
    iolist_to_binary(io_lib:format("~b.~b.~b.~b", [A, B, C, D]));
decode_ip(Hex, ipv6) ->
    %% 32 hex chars = 4 little-endian 32-bit words → 16 network-order bytes
    Int = binary_to_integer(Hex, 16),
    <<W0:32, W1:32, W2:32, W3:32>> = <<Int:128/big>>,
    <<B0:8, B1:8, B2:8, B3:8>> = <<W0:32/little>>,
    <<B4:8, B5:8, B6:8, B7:8>> = <<W1:32/little>>,
    <<B8:8, B9:8, B10:8, B11:8>> = <<W2:32/little>>,
    <<B12:8, B13:8, B14:8, B15:8>> = <<W3:32/little>>,
    Bytes = <<B0, B1, B2, B3, B4, B5, B6, B7, B8, B9, B10, B11, B12, B13, B14, B15>>,
    format_ipv6(Bytes).

%% Compact-ish IPv6 text (not full RFC 5952, but readable).
format_ipv6(<<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>) ->
    <<"::">>;
format_ipv6(<<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, A, B, C, D>>) ->
    %% IPv4-mapped
    iolist_to_binary(io_lib:format("::ffff:~b.~b.~b.~b", [A, B, C, D]));
format_ipv6(<<B0, B1, B2, B3, B4, B5, B6, B7, B8, B9, B10, B11, B12, B13, B14, B15>>) ->
    Groups = [
        (B0 bsl 8) bor B1,
        (B2 bsl 8) bor B3,
        (B4 bsl 8) bor B5,
        (B6 bsl 8) bor B7,
        (B8 bsl 8) bor B9,
        (B10 bsl 8) bor B11,
        (B12 bsl 8) bor B13,
        (B14 bsl 8) bor B15
    ],
    Parts = [iolist_to_binary(io_lib:format("~.16b", [G])) || G <- Groups],
    iolist_to_binary(lists:join(<<":">>, Parts)).

tcp_state_name(<<"udp">>, _) ->
    <<"">>;
tcp_state_name(<<"tcp">>, StHex) ->
    try
        case binary_to_integer(StHex, 16) of
            1 -> <<"ESTABLISHED">>;
            2 -> <<"SYN_SENT">>;
            3 -> <<"SYN_RECV">>;
            4 -> <<"FIN_WAIT1">>;
            5 -> <<"FIN_WAIT2">>;
            6 -> <<"TIME_WAIT">>;
            7 -> <<"CLOSE">>;
            8 -> <<"CLOSE_WAIT">>;
            9 -> <<"LAST_ACK">>;
            10 -> <<"LISTEN">>;
            11 -> <<"CLOSING">>;
            12 -> <<"NEW_SYN_RECV">>;
            N -> iolist_to_binary(io_lib:format("UNKNOWN(~b)", [N]))
        end
    catch
        _:_ ->
            StHex
    end;
tcp_state_name(_, St) ->
    St.
