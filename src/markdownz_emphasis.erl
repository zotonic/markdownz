%% @doc CommonMark emphasis delimiter scanning, balancing, and tree building.
%%
%% Delimiters are first collected as immutable data. A balancing pass then
%% pairs openers and closers, including CommonMark's rule of three. Finally,
%% the pair plan is folded into z_html_parse compatible nodes. This keeps the
%% grammar decisions separate from rendering and avoids special-case regular
%% expressions for particular combinations of `*' and `_'.
-module(markdownz_emphasis).

-export([plan/2, resolve/2]).

-type delimiter() :: #{
    marker := $* | $_,
    length := pos_integer(),
    position := non_neg_integer(),
    run := non_neg_integer(),
    can_open := boolean(),
    can_close := boolean(),
    pair := none | non_neg_integer()
}.
-type action() :: blank | {open, binary()} | {close, binary()}.
-type plan() :: #{
    actions := #{non_neg_integer() => action()},
    pairs := #{non_neg_integer() => non_neg_integer()}
}.

-spec plan(binary(), map()) -> plan().
plan(Source, State) ->
    Delimiters = scan(Source, State),
    Balanced = balance(Delimiters),
    #{
        actions => delimiter_actions(Balanced),
        pairs => delimiter_pairs(Balanced)
    }.

-spec resolve(binary(), map()) ->
    nomatch | {ok, [markdownz:html_element()], binary(), map()}.
resolve(<<Marker, _/binary>> = Source, State)
        when Marker =:= $*; Marker =:= $_ ->
    Offset = maps:get(markdownz_inline_offset, State, 0),
    #{actions := Actions, pairs := Pairs} =
        maps:get(markdownz_emphasis_plan, State),
    {RunLength, _} = count_prefix(Source, Marker),
    ClosingPositions = [
        maps:get(Position, Pairs)
        || Position <- lists:seq(Offset, Offset + RunLength - 1),
           maps:is_key(Position, Pairs)
    ],
    case ClosingPositions of
        [] ->
            nomatch;
        _ ->
            End = lists:max(ClosingPositions) + 1,
            PrefixLength = End - Offset,
            <<Prefix:PrefixLength/binary, Rest/binary>> = Source,
            Nodes = render(Prefix, Offset, End, Actions, State),
            {ok, Nodes, Rest, State}
    end;
resolve(_, _) ->
    nomatch.

-spec scan(binary(), map()) -> [delimiter()].
scan(Source, State) ->
    scan(Source, 0, none, 0, 0, State, []).

scan(<<>>, _Position, _Previous, _Run, _Index, _State, Acc) ->
    lists:reverse(Acc);
scan(Source, Position, Previous, Run, Index, State, Acc) ->
    case opaque_rest(Source, Previous, State) of
        {ok, Rest} ->
            ConsumedLength = byte_size(Source) - byte_size(Rest),
            <<Consumed:ConsumedLength/binary, _/binary>> = Source,
            scan(Rest, Position + ConsumedLength, last_codepoint(Consumed),
                Run, Index, State, Acc);
        nomatch ->
            scan_visible(Source, Position, Previous, Run, Index, State, Acc)
    end.

scan_visible(<<Marker, _/binary>> = Source, Position, Previous,
        Run, Index, State, Acc)
        when Marker =:= $*; Marker =:= $_ ->
    {Length, Rest} = count_prefix(Source, Marker),
    Next = first_codepoint(Rest),
    {LeftFlanking, RightFlanking} = delimiter_flanking(Previous, Next),
    CanOpen = can_open(Marker, LeftFlanking, RightFlanking, Previous),
    CanClose = can_close(Marker, LeftFlanking, RightFlanking, Next),
    {NewAcc, NewIndex} = add_run(
        Marker, Length, Position, Run, Index, CanOpen, CanClose, Acc),
    scan(Rest, Position + Length, Marker, Run + 1, NewIndex, State, NewAcc);
scan_visible(<<Char/utf8, Rest/binary>>, Position, _Previous,
        Run, Index, State, Acc) ->
    scan(Rest, Position + byte_size(<<Char/utf8>>), Char,
        Run, Index, State, Acc).

add_run(Marker, Length, Position, Run, Index, CanOpen, CanClose, Acc) ->
    add_run(0, Marker, Length, Position, Run, Index, CanOpen, CanClose, Acc).

add_run(Length, _Marker, Length, _Position, _Run, Index,
        _CanOpen, _CanClose, Acc) ->
    {Acc, Index};
add_run(Offset, Marker, Length, Position, Run, Index,
        CanOpen, CanClose, Acc) ->
    Delimiter = #{
        marker => Marker,
        length => Length,
        position => Position + Offset,
        run => Run,
        can_open => CanOpen,
        can_close => CanClose,
        pair => none
    },
    add_run(Offset + 1, Marker, Length, Position, Run, Index + 1,
        CanOpen, CanClose, [Delimiter | Acc]).

opaque_rest(<<$\\, _/binary>> = Source, _Previous, State) ->
    builtin_rest(escape, rule_escape, Source, State);
opaque_rest(<<"![", _/binary>> = Source, _Previous, State) ->
    builtin_rest(image, rule_image, Source, State);
opaque_rest(<<$[, _/binary>> = Source, _Previous, State) ->
    builtin_rest(link, rule_link, Source, State);
opaque_rest(<<$<, _/binary>> = Source, _Previous, State) ->
    first_result(
        builtin_rest(autolink, rule_autolink, Source, State),
        fun() -> builtin_rest(html, rule_html, Source, State) end);
opaque_rest(<<$`, _/binary>> = Source, _Previous, State) ->
    builtin_rest(code, rule_code, Source, State);
opaque_rest(<<"http://", _/binary>> = Source, _Previous, State) ->
    builtin_rest(linkify, rule_linkify, Source, State);
opaque_rest(<<"https://", _/binary>> = Source, _Previous, State) ->
    builtin_rest(linkify, rule_linkify, Source, State);
opaque_rest(<<"www.", _/binary>> = Source, _Previous, State) ->
    builtin_rest(linkify, rule_linkify, Source, State);
opaque_rest(<<"//", _/binary>> = Source, _Previous, State) ->
    builtin_rest(linkify, rule_linkify, Source, State);
opaque_rest(<<"~~", _/binary>> = Source, _Previous, State) ->
    builtin_rest(strikethrough, rule_strikethrough, Source, State);
opaque_rest(<<$~, _/binary>> = Source, _Previous, State) ->
    builtin_rest(subscript, rule_subscript, Source, State);
opaque_rest(<<$^, _/binary>> = Source, _Previous, State) ->
    builtin_rest(superscript, rule_superscript, Source, State);
opaque_rest(Source, Previous, State) ->
    case email_candidate(Source, Previous) of
        true -> builtin_rest(linkify, rule_linkify, Source, State);
        false -> nomatch
    end.

%% Linkify is deliberately not attempted at every byte: its anchored email
%% regular expression would make long non-matching input quadratic. Inline
%% linkification starts at a token boundary, so one attempt per whitespace-
%% delimited token is sufficient while still making email delimiters opaque.
email_candidate(<<Char, _/binary>>, Previous) ->
    is_email_boundary(Previous) andalso is_email_local_char(Char);
email_candidate(<<>>, _Previous) ->
    false.

is_email_boundary(Char) -> is_space_or_boundary(Char).

is_email_local_char(Char) when Char >= $a, Char =< $z -> true;
is_email_local_char(Char) when Char >= $A, Char =< $Z -> true;
is_email_local_char(Char) when Char >= $0, Char =< $9 -> true;
is_email_local_char(Char) ->
    lists:member(Char, ".!#$%&'*+/=?^_`{|}~-").

first_result({ok, _Rest} = Result, _Next) ->
    Result;
first_result(nomatch, Next) ->
    Next().

builtin_rest(Name, Function, Source, State) ->
    #{config := #{rulers := #{inline := Ruler}}} = State,
    Handler = {markdownz_inline, Function},
    case lists:any(
            fun(#{name := RuleName, handler := RuleHandler}) ->
                RuleName =:= Name andalso RuleHandler =:= Handler
            end,
            markdownz_ruler:rules(Ruler)) of
        true ->
            result_rest(markdownz_inline:Function(Source, State));
        false ->
            nomatch
    end.

result_rest({ok, _Nodes, Rest, _State}) -> {ok, Rest};
result_rest(nomatch) -> nomatch.

balance([]) ->
    [];
balance(Delimiters) ->
    Array0 = array:from_list(Delimiters),
    Size = array:size(Array0),
    {Array, _Bottom, _Jumps, _Header, _ForceHeader} =
        balance(0, Size, Array0, #{}, #{}, 0, false),
    array:to_list(Array).

balance(Index, Size, Array, Bottom, Jumps, Header, ForceHeader)
        when Index >= Size ->
    {Array, Bottom, Jumps, Header, ForceHeader};
balance(Index, Size, Array0, Bottom0, Jumps0, Header0, ForceHeader) ->
    Closer0 = array:get(Index, Array0),
    Header = case ForceHeader orelse
            maps:get(run, array:get(Header0, Array0)) =/= maps:get(run, Closer0) of
        true -> Index;
        false -> Header0
    end,
    Jumps = maps:put(Index, maps:get(Index, Jumps0, 0), Jumps0),
    case maps:get(can_close, Closer0) of
        false ->
            balance(Index + 1, Size, Array0, Bottom0, Jumps,
                Header, false);
        true ->
            Key = {
                maps:get(marker, Closer0),
                maps:get(can_open, Closer0),
                maps:get(length, Closer0) rem 3
            },
            Minimum = maps:get(Key, Bottom0, -1),
            Start = Header - maps:get(Header, Jumps, 0) - 1,
            case find_opener(Start, Minimum, Closer0, Array0, Jumps) of
                {ok, OpenerIndex} ->
                    {Array, NewJumps} = pair(
                        OpenerIndex, Index, Array0, Jumps),
                    balance(Index + 1, Size, Array, Bottom0, NewJumps,
                        Header, true);
                nomatch ->
                    Bottom = Bottom0#{Key => Start},
                    balance(Index + 1, Size, Array0, Bottom, Jumps,
                        Header, false)
            end
    end.

find_opener(Index, Minimum, _Closer, _Array, _Jumps)
        when Index =< Minimum ->
    nomatch;
find_opener(Index, Minimum, Closer, Array, Jumps) ->
    Opener = array:get(Index, Array),
    IsCandidate =
        maps:get(marker, Opener) =:= maps:get(marker, Closer)
        andalso maps:get(can_open, Opener)
        andalso maps:get(pair, Opener) =:= none
        andalso not odd_match(Opener, Closer),
    case IsCandidate of
        true -> {ok, Index};
        false ->
            find_opener(Index - maps:get(Index, Jumps, 0) - 1,
                Minimum, Closer, Array, Jumps)
    end.

odd_match(Opener, Closer) ->
    case maps:get(can_close, Opener) orelse maps:get(can_open, Closer) of
        false -> false;
        true ->
            OpenerLength = maps:get(length, Opener),
            CloserLength = maps:get(length, Closer),
            (OpenerLength + CloserLength) rem 3 =:= 0
                andalso (OpenerLength rem 3 =/= 0
                    orelse CloserLength rem 3 =/= 0)
    end.

pair(OpenerIndex, CloserIndex, Array0, Jumps0) ->
    LastJump = case OpenerIndex > 0 of
        true ->
            Previous = array:get(OpenerIndex - 1, Array0),
            case maps:get(can_open, Previous) of
                false -> maps:get(OpenerIndex - 1, Jumps0, 0) + 1;
                true -> 0
            end;
        false -> 0
    end,
    Opener = array:get(OpenerIndex, Array0),
    Closer = array:get(CloserIndex, Array0),
    Array1 = array:set(OpenerIndex,
        Opener#{pair := CloserIndex, can_close := false}, Array0),
    Array = array:set(CloserIndex, Closer#{can_open := false}, Array1),
    Jumps = Jumps0#{
        CloserIndex => CloserIndex - OpenerIndex + LastJump,
        OpenerIndex => LastJump
    },
    {Array, Jumps}.

delimiter_pairs(Delimiters) ->
    Array = array:from_list(Delimiters),
    delimiter_pairs(Delimiters, Array, #{}).

delimiter_pairs([], _Array, Pairs) ->
    Pairs;
delimiter_pairs([#{position := Position, pair := Pair} | Rest],
        Array, Pairs0) when is_integer(Pair) ->
    Closer = array:get(Pair, Array),
    Pairs = Pairs0#{Position => maps:get(position, Closer)},
    delimiter_pairs(Rest, Array, Pairs);
delimiter_pairs([_Delimiter | Rest], Array, Pairs) ->
    delimiter_pairs(Rest, Array, Pairs).

delimiter_actions(Delimiters) ->
    Array = array:from_list(Delimiters),
    delimiter_actions(array:size(Array) - 1, Array, #{}).

delimiter_actions(Index, _Array, Actions) when Index < 0 ->
    Actions;
delimiter_actions(Index, Array, Actions0) ->
    Opener = array:get(Index, Array),
    case maps:get(pair, Opener) of
        none ->
            delimiter_actions(Index - 1, Array, Actions0);
        PairIndex ->
            case is_strong_pair(Index, PairIndex, Array) of
                true ->
                    Previous = array:get(Index - 1, Array),
                    Closer = array:get(PairIndex, Array),
                    NextCloser = array:get(PairIndex + 1, Array),
                    Actions = Actions0#{
                        maps:get(position, Previous) => blank,
                        maps:get(position, Opener) => {open, <<"strong">>},
                        maps:get(position, Closer) => {close, <<"strong">>},
                        maps:get(position, NextCloser) => blank
                    },
                    delimiter_actions(Index - 2, Array, Actions);
                false ->
                    Closer = array:get(PairIndex, Array),
                    Actions = Actions0#{
                        maps:get(position, Opener) => {open, <<"em">>},
                        maps:get(position, Closer) => {close, <<"em">>}
                    },
                    delimiter_actions(Index - 1, Array, Actions)
            end
    end.

is_strong_pair(Index, PairIndex, Array) when Index > 0 ->
    Previous = array:get(Index - 1, Array),
    Opener = array:get(Index, Array),
    Size = array:size(Array),
    case maps:get(pair, Previous) of
        PreviousPair when PreviousPair =:= PairIndex + 1,
                PairIndex + 1 < Size ->
            Closer = array:get(PairIndex, Array),
            NextCloser = array:get(PairIndex + 1, Array),
            maps:get(marker, Previous) =:= maps:get(marker, Opener)
                andalso maps:get(position, Previous) + 1
                    =:= maps:get(position, Opener)
                andalso maps:get(position, Closer) + 1
                    =:= maps:get(position, NextCloser);
        _ -> false
    end;
is_strong_pair(_Index, _PairIndex, _Array) ->
    false.

render(Source, Start, End, Actions, State) ->
    %% Walking only the consumed range prevents repeated scans of the complete
    %% action map when a line contains many separate emphasis spans.
    Events = [
        {Position, maps:get(Position, Actions)}
        || Position <- lists:seq(Start, End - 1),
           maps:is_key(Position, Actions)
    ],
    {Nodes, []} = render_events(Events, Source, Start, 0, [], [], State),
    merge_text(lists:reverse(Nodes)).

render_events([], Source, _Start, Cursor, Current, Frames, State) ->
    Tail = binary:part(Source, Cursor, byte_size(Source) - Cursor),
    {append_raw(Tail, Current, State), Frames};
render_events([{Position, Action} | Rest], Source, Start, Cursor,
        Current0, Frames0, State) ->
    LocalPosition = Position - Start,
    Raw = binary:part(Source, Cursor, LocalPosition - Cursor),
    Current = append_raw(Raw, Current0, State),
    {NewCurrent, NewFrames} = apply_action(Action, Current, Frames0),
    render_events(Rest, Source, Start, LocalPosition + 1,
        NewCurrent, NewFrames, State).

apply_action(blank, Current, Frames) ->
    {Current, Frames};
apply_action({open, Tag}, Current, Frames) ->
    {[], [{Tag, Current} | Frames]};
apply_action({close, Tag}, Current, [{Tag, Parent} | Frames]) ->
    Node = {Tag, [], merge_text(lists:reverse(Current))},
    {[Node | Parent], Frames}.

append_raw(<<>>, Current, _State) ->
    Current;
append_raw(Raw, Current, State) ->
    CleanState = maps:without(
        [markdownz_emphasis_plan, markdownz_inline_offset], State),
    {Nodes, _} = markdownz_inline:parse(Raw, CleanState),
    lists:reverse(Nodes, Current).

merge_text(Nodes) ->
    lists:reverse(lists:foldl(
        fun(Text, [Previous | Rest]) when is_binary(Text), is_binary(Previous) ->
                [<<Previous/binary, Text/binary>> | Rest];
           (Node, Acc) ->
                [Node | Acc]
        end,
        [],
        Nodes)).

can_open($_, Left, Right, Previous) ->
    Left andalso (not Right orelse is_punctuation(Previous));
can_open($*, Left, _Right, _Previous) ->
    Left.

can_close($_, Left, Right, Next) ->
    Right andalso (not Left orelse is_punctuation(Next));
can_close($*, _Left, Right, _Next) ->
    Right.

delimiter_flanking(Previous, Next) ->
    Left = not is_space_or_boundary(Next)
        andalso (not is_punctuation(Next)
            orelse is_space_or_boundary(Previous)
            orelse is_punctuation(Previous)),
    Right = not is_space_or_boundary(Previous)
        andalso (not is_punctuation(Previous)
            orelse is_space_or_boundary(Next)
            orelse is_punctuation(Next)),
    {Left, Right}.

first_codepoint(<<Char/utf8, _/binary>>) -> Char;
first_codepoint(<<>>) -> none.

is_space_or_boundary(none) -> true;
is_space_or_boundary(Char) ->
    is_space(Char) orelse
        re:run(<<Char/utf8>>, <<"^[\\p{Z}]$">>,
            [unicode, {capture, none}]) =:= match.

is_space(Char) ->
    lists:member(Char, [$\s, $\t, $\n, $\r, $\f, $\v]).

is_punctuation(none) -> false;
is_punctuation(Char) ->
    re:run(<<Char/utf8>>, <<"^[\\p{P}\\p{S}]$">>,
        [unicode, {capture, none}]) =:= match.

count_prefix(Bin, Char) -> count_prefix(Bin, Char, 0).
count_prefix(<<Char, Rest/binary>>, Char, Count) ->
    count_prefix(Rest, Char, Count + 1);
count_prefix(Rest, _Char, Count) ->
    {Count, Rest}.

last_codepoint(Bin) ->
    [Last | _] = lists:reverse(unicode:characters_to_list(Bin)),
    Last.
