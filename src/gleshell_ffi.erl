%% Erlang FFI for gleshell: REPL I/O, cwd, env, external processes.
-module(gleshell_ffi).
-include_lib("kernel/include/file.hrl").
-export([
    get_line/1,
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
    home_dir/0,
    stdout_isatty/0,
    println/1,
    take_output_shown/0,
    clear_output_shown/0,
    complete_word/2,
    re_contains/3
]).

-define(ESC, 16#1b).
-define(CSI_CLEAR_EOL, "\e[K").
-define(HISTORY_MAX, 2000).

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
    History = case get(gleshell_history) of
        L when is_list(L) -> L;
        _ -> []
    end,
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
                    raw_loop(Prompt, Left, Right, History, HistPos, Saved);
                [C | Rest] ->
                    redraw(Prompt, [C | Left], Rest),
                    raw_loop(Prompt, [C | Left], Rest, History, HistPos, Saved)
            end;
        home ->
            NewRight = lists:reverse(Left) ++ Right,
            redraw(Prompt, [], NewRight),
            raw_loop(Prompt, [], NewRight, History, HistPos, Saved);
        'end' ->
            NewLeft = lists:reverse(Right) ++ Left,
            redraw(Prompt, NewLeft, []),
            raw_loop(Prompt, NewLeft, [], History, HistPos, Saved);
        up ->
            hist_nav(Prompt, Left, Right, History, HistPos, Saved, 1);
        down ->
            hist_nav(Prompt, Left, Right, History, HistPos, Saved, -1);
        ctrl_a ->
            NewRight = lists:reverse(Left) ++ Right,
            redraw(Prompt, [], NewRight),
            raw_loop(Prompt, [], NewRight, History, HistPos, Saved);
        ctrl_e ->
            NewLeft = lists:reverse(Right) ++ Left,
            redraw(Prompt, NewLeft, []),
            raw_loop(Prompt, NewLeft, [], History, HistPos, Saved);
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
            reverse_search(Prompt, History);
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
        "append", "cat", "cd", "columns", "count", "describe", "echo", "env",
        "exit", "filter", "find", "first", "flatten", "from", "get", "help",
        "identity", "ignore", "is-empty", "is_empty", "keys", "last", "length",
        "lines", "ls", "open", "prepend", "print", "pwd", "quit", "range",
        "reverse", "save", "select", "skip", "sort-by", "sort_by", "sys",
        "table", "take", "to", "type", "typeof", "uniq", "unwrap",
        "values", "where", "which", "wrap"
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
    NewPos = HistPos + Delta,
    Len = length(History),
    if
        NewPos < 0 ->
            raw_loop(Prompt, Left, Right, History, HistPos, Saved);
        NewPos =:= 0 ->
            %% Restore saved draft
            {L, R} = bin_to_buffer(Saved),
            redraw(Prompt, L, R),
            raw_loop(Prompt, L, R, History, 0, <<>>);
        NewPos > Len ->
            raw_loop(Prompt, Left, Right, History, HistPos, Saved);
        true ->
            NewSaved = case HistPos of
                0 -> buffer_to_bin(Left, Right);
                _ -> Saved
            end,
            Entry = lists:nth(NewPos, History),
            {L, R} = bin_to_buffer(Entry),
            redraw(Prompt, L, R),
            raw_loop(Prompt, L, R, History, NewPos, NewSaved)
    end.

%% Minimal Ctrl+R reverse-i-search over history.
reverse_search(Prompt, History) ->
    reverse_search_loop(Prompt, History, [], match_history(History, [])).

reverse_search_loop(Prompt, History, Query, Match) ->
    Hint = unicode:characters_to_list(
        ["(reverse-i-search)`", Query, "': ", Match]
    ),
    io:put_chars([$\r, Hint, ?CSI_CLEAR_EOL]),
    case read_key() of
        eof ->
            io:put_chars("\r\n"),
            {error, <<"eof">>};
        enter ->
            %% Accept match onto the edit line; do not submit (edit first).
            Line = iolist_to_binary(Match),
            {L, R} = bin_to_buffer(Line),
            redraw(Prompt, L, R),
            raw_loop(Prompt, L, R, History, 0, <<>>);
        ctrl_c ->
            io:put_chars("\r\n"),
            redraw(Prompt, [], []),
            raw_loop(Prompt, [], [], History, 0, <<>>);
        ctrl_g ->
            redraw(Prompt, [], []),
            raw_loop(Prompt, [], [], History, 0, <<>>);
        ctrl_r ->
            %% Find older match
            NewMatch = match_history_after(History, Query, Match),
            reverse_search_loop(Prompt, History, Query, NewMatch);
        backspace ->
            NewQuery = case Query of
                [] -> [];
                [_ | _] -> lists:droplast(Query)
            end,
            reverse_search_loop(
                Prompt, History, NewQuery, match_history(History, NewQuery)
            );
        {char, C} when is_integer(C), C >= 32, C =/= 127 ->
            NewQuery = Query ++ [C],
            reverse_search_loop(
                Prompt, History, NewQuery, match_history(History, NewQuery)
            );
        _ ->
            reverse_search_loop(Prompt, History, Query, Match)
    end.

match_history(_History, []) ->
    "";
match_history(History, Query) ->
    QBin = unicode:characters_to_binary(Query),
    case first_match(History, QBin) of
        undefined -> "";
        Bin -> unicode:characters_to_list(Bin)
    end.

match_history_after(History, Query, CurrentMatch) ->
    QBin = unicode:characters_to_binary(Query),
    CurBin = unicode:characters_to_binary(CurrentMatch),
    case skip_until_then_match(History, CurBin, QBin, false) of
        undefined -> CurrentMatch;
        Bin -> unicode:characters_to_list(Bin)
    end.

first_match([], _) ->
    undefined;
first_match([H | T], Q) ->
    case binary:match(H, Q) of
        nomatch -> first_match(T, Q);
        _ -> H
    end.

skip_until_then_match([], _Cur, _Q, _Seen) ->
    undefined;
skip_until_then_match([H | T], Cur, Q, false) ->
    case H =:= Cur of
        true -> skip_until_then_match(T, Cur, Q, true);
        false -> skip_until_then_match(T, Cur, Q, false)
    end;
skip_until_then_match([H | T], Cur, Q, true) ->
    case binary:match(H, Q) of
        nomatch -> skip_until_then_match(T, Cur, Q, true);
        _ -> H
    end.

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
    FullBin = unicode:characters_to_binary(Full),
    Colored = highlight_line(FullBin),
    io:put_chars([$\r, Prompt, Colored, ?CSI_CLEAR_EOL]),
    case length(Right) of
        0 ->
            ok;
        N ->
            io:put_chars(["\e[", integer_to_list(N), $D])
    end.

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
decode_key(?ESC, _) ->
    read_escape();
decode_key(C, _) when is_integer(C), C >= 32 ->
    {char, C};
decode_key(_, _) ->
    other.

read_escape() ->
    case io:get_chars("", 1) of
        eof ->
            other;
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
        _ ->
            other
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
            Lines = [
                L
             || L <- binary:split(Bin, <<"\n">>, [global]),
                L =/= <<>>
            ],
            %% Newest first
            put(gleshell_history, lists:reverse(Lines));
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
            %% Store oldest-first for human readability
            Body = [[L, $\n] || L <- lists:reverse(lists:sublist(Hist, ?HISTORY_MAX))],
            _ = file:write_file(File, Body),
            ok;
        _ ->
            ok
    end.

push_history(<<>>) ->
    ok;
push_history(Line) when is_binary(Line) ->
    Hist = case get(gleshell_history) of
        L when is_list(L) -> L;
        _ -> []
    end,
    New = case Hist of
        [Line | _] -> Hist;
        _ -> [Line | Hist]
    end,
    put(gleshell_history, lists:sublist(New, ?HISTORY_MAX)),
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
%%    non-TTY). Uses pipes; the child does NOT get a real terminal.
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

%% Capture mode: pipes, no TTY. `child_env` forces color when the shell wants
%% it so tools like `jj` still embed ANSI we can pass through on display.
%%
%% Stdin is always redirected via `sh -c` + `$GLESHELL_STDIN` (either a temp
%% file with pipeline bytes, or `/dev/null`) so programs never hang on an
%% open-but-never-written Erlang port pipe.
run_cmd_capture(Path, PortArgs, Stdin) when is_binary(Stdin) ->
    with_stdin_file(Stdin, fun(StdinPath) ->
        sh_exec(Path, PortArgs, StdinPath, capture)
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
        {gleshell_interrupt, _} ->
            signal_port_group(Port, kill),
            collect_output_relay_after_interrupt(Port, Tty, Acc, 1000)
    after GraceMs ->
        signal_port_group(Port, kill),
        catch port_close(Port),
        receive
            {Port, {exit_status, Status}} ->
                {ok, {Status, normalize_pty_output(Acc)}}
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
%% - LESS=FRX when unset: pagers (jj/git → less) pass through ANSI colors (-R)
%%   and exit on short output (-F) without clearing the screen (-X).
%% - FORCE_COLOR / CLICOLOR_FORCE when the shell itself wants color and the
%%   child has no TTY (direct path): tools like jj/git/ripgrep emit ANSI so
%%   we can show their colors when re-printing the captured string.
child_env() ->
    Env0 = [{"SHELL", "/bin/sh"}],
    Env1 =
        case os:getenv("LESS") of
            false ->
                [{"LESS", "FRX"} | Env0];
            "" ->
                [{"LESS", "FRX"} | Env0];
            _ ->
                Env0
        end,
    case want_child_color() of
        false ->
            Env1;
        true ->
            Env2 =
                case os:getenv("FORCE_COLOR") of
                    false ->
                        [{"FORCE_COLOR", "1"} | Env1];
                    "0" ->
                        Env1;
                    _ ->
                        Env1
                end,
            case os:getenv("CLICOLOR_FORCE") of
                false ->
                    [{"CLICOLOR_FORCE", "1"} | Env2];
                "0" ->
                    Env2;
                _ ->
                    Env2
            end
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
