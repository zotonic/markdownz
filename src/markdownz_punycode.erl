%% @doc RFC 3492 Punycode encoding and decoding for individual DNS labels.
-module(markdownz_punycode).

-export([encode/1, decode/1]).

-define(BASE, 36).
-define(TMIN, 1).
-define(TMAX, 26).
-define(SKEW, 38).
-define(DAMP, 700).
-define(INITIAL_BIAS, 72).
-define(INITIAL_N, 128).

-spec encode(binary()) -> {ok, binary()} | error.
encode(Label) ->
    case unicode:characters_to_list(Label) of
        Codepoints when is_list(Codepoints) ->
            try
                Basic = [Codepoint || Codepoint <- Codepoints, Codepoint < 128],
                BasicCount = length(Basic),
                Output = case BasicCount > 0 andalso BasicCount < length(Codepoints) of
                    true -> Basic ++ [$-];
                    false -> Basic
                end,
                Encoded = encode(Codepoints, ?INITIAL_N, 0, ?INITIAL_BIAS,
                    BasicCount, BasicCount, Output),
                {ok, list_to_binary(Encoded)}
            catch
                error:badarg -> error
            end;
        _ ->
            error
    end.

encode(Input, _N, _Delta, _Bias, Handled, _BasicCount, Output)
        when Handled =:= length(Input) ->
    Output;
encode(Input, N, Delta0, Bias, Handled0, BasicCount, Output0) ->
    M = lists:min([Codepoint || Codepoint <- Input, Codepoint >= N]),
    Delta = Delta0 + (M - N) * (Handled0 + 1),
    {NextDelta, NextBias, Handled, Output} = encode_codepoints(
        Input, M, Delta, Bias, Handled0, BasicCount, Output0),
    encode(Input, M + 1, NextDelta + 1, NextBias,
        Handled, BasicCount, Output).

encode_codepoints([], _N, Delta, Bias, Handled, _BasicCount, Output) ->
    {Delta, Bias, Handled, Output};
encode_codepoints([Codepoint | Rest], N, Delta0, Bias0,
        Handled0, BasicCount, Output0) ->
    Delta = case Codepoint < N of
        true -> Delta0 + 1;
        false -> Delta0
    end,
    case Codepoint =:= N of
        true ->
            Digits = encode_delta(Delta, Bias0, ?BASE, []),
            Handled = Handled0 + 1,
            Bias = adapt(Delta, Handled, Handled0 =:= BasicCount),
            encode_codepoints(Rest, N, 0, Bias, Handled,
                BasicCount, Output0 ++ Digits);
        false ->
            encode_codepoints(Rest, N, Delta, Bias0, Handled0,
                BasicCount, Output0)
    end.

encode_delta(Q, Bias, K, Acc) ->
    T = threshold(K, Bias),
    case Q < T of
        true ->
            lists:reverse([encode_digit(Q) | Acc]);
        false ->
            Digit = T + ((Q - T) rem (?BASE - T)),
            encode_delta((Q - T) div (?BASE - T), Bias, K + ?BASE,
                [encode_digit(Digit) | Acc])
    end.

-spec decode(binary()) -> {ok, binary()} | error.
decode(Label) ->
    try
        {Basic, Encoded} = split_basic(Label),
        true = lists:all(fun(Byte) -> Byte < 128 end, binary_to_list(Basic)),
        Output0 = binary_to_list(Basic),
        Codepoints = decode(Encoded, ?INITIAL_N, 0, ?INITIAL_BIAS, Output0),
        case valid_codepoints(Codepoints) of
            true -> {ok, unicode:characters_to_binary(Codepoints)};
            false -> error
        end
    catch
        error:_ -> error
    end.

decode(<<>>, _N, _I, _Bias, Output) ->
    Output;
decode(Input, N0, I0, Bias0, Output0) ->
    OldI = I0,
    {Rest, I1} = decode_delta(Input, Bias0, ?BASE, I0, 1),
    OutputLength = length(Output0) + 1,
    Bias = adapt(I1 - OldI, OutputLength, OldI =:= 0),
    N = N0 + I1 div OutputLength,
    Position = I1 rem OutputLength,
    {Before, After} = lists:split(Position, Output0),
    Output = Before ++ [N | After],
    decode(Rest, N, Position + 1, Bias, Output).

decode_delta(<<DigitChar, Rest/binary>>, Bias, K, I, Weight) ->
    Digit = decode_digit(DigitChar),
    NextI = I + Digit * Weight,
    T = threshold(K, Bias),
    case Digit < T of
        true -> {Rest, NextI};
        false -> decode_delta(Rest, Bias, K + ?BASE, NextI,
            Weight * (?BASE - T))
    end.

split_basic(Label) ->
    case binary:matches(Label, <<"-">>) of
        [] ->
            {<<>>, Label};
        Matches ->
            {Position, 1} = lists:last(Matches),
            Basic = binary:part(Label, 0, Position),
            EncodedPosition = Position + 1,
            Encoded = binary:part(Label, EncodedPosition,
                byte_size(Label) - EncodedPosition),
            {Basic, Encoded}
    end.

adapt(Delta0, NumberOfPoints, FirstTime) ->
    Delta1 = case FirstTime of
        true -> Delta0 div ?DAMP;
        false -> Delta0 div 2
    end,
    Delta = Delta1 + Delta1 div NumberOfPoints,
    adapt_bias(Delta, 0).

adapt_bias(Delta, K) when Delta > ((?BASE - ?TMIN) * ?TMAX) div 2 ->
    adapt_bias(Delta div (?BASE - ?TMIN), K + ?BASE);
adapt_bias(Delta, K) ->
    K + ((?BASE - ?TMIN + 1) * Delta) div (Delta + ?SKEW).

threshold(K, Bias) when K =< Bias + ?TMIN -> ?TMIN;
threshold(K, Bias) when K >= Bias + ?TMAX -> ?TMAX;
threshold(K, Bias) -> K - Bias.

encode_digit(Digit) when Digit < 26 -> $a + Digit;
encode_digit(Digit) -> $0 + Digit - 26.

decode_digit(Char) when Char >= $a, Char =< $z -> Char - $a;
decode_digit(Char) when Char >= $A, Char =< $Z -> Char - $A;
decode_digit(Char) when Char >= $0, Char =< $9 -> Char - $0 + 26.

valid_codepoints(Codepoints) ->
    lists:all(
        fun(Codepoint) ->
            Codepoint >= 0 andalso Codepoint =< 16#10ffff
                andalso not (Codepoint >= 16#d800
                    andalso Codepoint =< 16#dfff)
        end,
        Codepoints).
