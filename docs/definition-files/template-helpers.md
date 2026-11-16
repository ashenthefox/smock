# Template helpers

This document of the [Definition-file reference](../definition-files.md)
lists the helpers, the functions that a template calls, such as
`${fake.uuid()}`. It assumes [Templates](templates.md): expressions and
`??`, missing values, text and structured templates, and `$each`.
[How helpers read their arguments](#how-helpers-read-their-arguments)
gives the rules by which the string helpers and the families after them
read their arguments, and [The random source and the time of a
request](#the-random-source-and-the-time-of-a-request) says how helpers
draw from the Stub's random source and which time `now()` reads.

Helpers come in families. Each family says how many arguments its helpers
take, and which of them must be literals.

## Contents

- [Fake data](#fake-data)
- [Time](#time)
- [Conversions](#conversions)
- [Strings](#strings)
- [Arrays](#arrays)
- [Encodings](#encodings)
- [JWTs](#jwts)
- [Dates](#dates)
- [How helpers read their arguments](#how-helpers-read-their-arguments)
- [Arithmetic](#arithmetic)
- [The random source and the time of a request](#the-random-source-and-the-time-of-a-request)

## Fake data

Every argument is a literal.

| Helper | Arguments | Output |
|---|---|---|
| `fake.uuid()` | none | A version 4 UUID in lower case. |
| `fake.int(min, max)` | integer literals from -(2^53 - 1) to 2^53 - 1 | An integer from `min` to `max`, both included, each equally likely. |
| `fake.decimal(min, max, places)` | integer literals from -10^9 to 10^9; `places` from 1 to 6 | A number from `min` to `max` in steps of 10^-places, written with exactly `places` decimals, such as `104.30`. |
| `fake.bool()` | none | `true` or `false`. |
| `fake.pick(v1, …, vn)` | 1 to 100 literals | One of them, with its type. |
| `fake.hex(n)` | `n` from 1 to 64 | `n` lower-case hex digits. |
| `fake.word()`, `fake.words(n)` | `n` from 1 to 100 | One word, or `n` words separated by spaces, from a built-in list of 256 lower-case English words. |
| `fake.firstName()`, `fake.lastName()`, `fake.name()` | none | A first name, a last name, or both, from built-in lists of 128 ASCII names each. |
| `fake.email()` | none | `<first>.<last><nn>@example.com` in lower case. |

## Time

The argument, if any, is a literal.

| Helper | Arguments | Output |
|---|---|---|
| `now()`, `now(s)` | `s`: an integer literal, seconds, may be negative | The time of the request plus `s` seconds, RFC 3339 in UTC with milliseconds. |
| `now(format)` | `format`: a string literal, a format as for [Dates](#dates) below | The time of the request, in UTC, written in `format`. |
| `nowMillis()`, `nowMillis(s)` | as for `now` | The same instant in milliseconds since the Unix epoch. |

## Conversions

Each argument may be any expression.

| Helper | Arguments | Output |
|---|---|---|
| `number(x)` | a string or a number | `x` as a number. |
| `range(a, b)` | integers from -(2^53 - 1) to 2^53 - 1 | The integers from `a` to `b`, for `$each`; none when `a > b`. |
| `json(x)` | any value | Text templates only: `x` written as JSON. |
| `raw(x)` | a string, number, boolean or null | Text templates only: `x` without escaping. |

A bound of `range` can be any expression that gives an integer, such as
`len(body.items)`; a string is not one, so write `number(query.n)` for a
bound from the query. A bound that is not an integer in range is an error
when the template is rendered. Literal bounds, and the limit of 1000
values when both bounds are literals, are checked when the files are
loaded.

## Strings

Each argument may be any expression. Lengths count Unicode
code points, so an emoji or a Japanese character counts as one.

| Helper | Arguments | Output |
|---|---|---|
| `len(x)` | text, or an array | The length of the text in code points, or the number of elements of the array. |
| `concat(a, b, …)` | 2 to 100 texts | The texts joined. |
| `padStart(s, length, pad)`, `padEnd(s, length, pad)` | text; an integer; text, by default one space | `s` padded at its start or end to `length` code points, the pad repeated and cut to fit, as JavaScript does. A text that long already, or an empty pad, is unchanged. |
| `substr(s, from, length)` | text; an integer; an integer, by default the rest | The code points of `s` from `from`, `length` of them. A negative `from` counts from the end. Positions out of range clamp, so `substr('abc', 5)` and a negative `length` give an empty text. |
| `indexOf(s, search, from)` | text; text; an integer, by default 0 | The code-point index of the first `search` in `s` at or after `from`, or -1 when there is none. A negative `from` counts as 0, and a `from` past the end gives -1. |
| `includes(s, search)` | text; text | `true` when `search` occurs in `s`, otherwise `false`. An empty search occurs in every text. |
| `replace(s, search, replacement)`, `replaceAll(s, search, replacement)` | text | `s` with the first, or every, occurrence of `search` replaced, found from the start without overlap. Both are literal text: `$&` and `$1` are written as they are. An empty search leaves `s` unchanged. |
| `split(s, separator)` | text; text | An array of the texts between the occurrences of `separator`, found from the start. An empty separator splits into code points. An empty `s` gives `[""]`, whatever the separator. |
| `join(array, separator)` | an array; text | The elements written as text, with `separator` between them. `null` is written as an empty text. An object or an array as an element is an error. |
| `uppercase(s)`, `lowercase(s)` | text | `s` with each code point mapped to its upper or lower case, one code point to one. |
| `trim(s)` | text | `s` without White_Space at either end. |

```yaml
response:
  status: 200
  template: true
  json:
    code: ${padStart(query.n, 6, '0')}
    name: ${concat(body.first, ' ', body.last)}
    lines: { $each: "range(1, len(body.items))", as: i, do: "${i}" }
```

`?n=42` with the body `{"first":"Ann","last":"Lee","items":["a","b"]}` gets
`{"code":"000042","name":"Ann Lee","lines":[1,2]}`.

The array that `split` gives can be a `$each` source, the whole value of a
`${…}` in a structured template, or read with a step. In text, write it
with `json(…)`. `join` turns an array back into text:

```yaml
response:
  status: 200
  template: true
  json:
    ids: { $each: "split(query.ids, ',')", as: id, do: "${id}" }
    first: ${split(query.ids, ',')[0]}
    tags: ${join(body.tags, '|')}
    short: ${substr(body.name, 0, 3)}
```

`?ids=a,b,c` with the body `{"tags":["x",null,1],"name":"東京タワー"}` gets
`{"ids":["a","b","c"],"first":"a","tags":"x||1","short":"東京タ"}`.

`uppercase`, `lowercase` and `trim` read the data of Unicode 18.0.0, which
is built into smock. That data does not change within format version 1, so
they give the same output on every machine and in every release.

- Case mapping is the simple one in the Unicode Character Database: each
  code point maps to one code point, whatever the locale. There is no
  special casing, so `ß`, whose upper case is two letters, stays `ß`, and
  `İ` becomes `i`. Characters without case, such as digits, Japanese text
  or emoji, stay as they are.
- `trim` removes the code points with the Unicode property White_Space:
  tab, line feed, the other ASCII spaces and line breaks, and those beyond
  ASCII, such as U+00A0 NO-BREAK SPACE and U+3000 IDEOGRAPHIC SPACE. U+200B
  ZERO WIDTH SPACE and U+FEFF ZERO WIDTH NO-BREAK SPACE are not White_Space,
  so they stay.

```yaml
response:
  status: 200
  template: true
  json:
    code: ${uppercase(body.code)}
    name: ${trim(query.name)}
```

The body `{"code":"straße-ç"}` with `?name=%E3%80%80Ann%20` (an ideographic
space before the name, a space after it) gets
`{"code":"STRAßE-Ç","name":"Ann"}`.

## Arrays

Each argument may be any expression.

| Helper | Arguments | Output |
|---|---|---|
| `find(array, member, value)` | an array; a string; a string, a number, a boolean or null | The first element of `array` that is an object whose member `member` meets `value`. |
| `last(array)` | an array | The last element of `array`, with its own type. |

`value` is taken as text: a string as it is, a number as smock writes it
in `json`, and `true`, `false` and `null` as those words. Unlike the
string helpers, `find` takes `null`. A member meets the value when:

- it is a string equal to that text;
- it is a number, and the text is a JSON number of equal value, compared as
  [`json` conditions](matching.md#how-a-stub-matches-a-request) compare
  numbers: `12.50` meets `12.5`, and integers beyond 2^53 are compared
  exactly;
- it is `true`, `false` or `null`, and the text is that word.

Objects, arrays and absent members never meet the value. So
`find(body.orders, 'id', 1004)`, `find(body.orders, 'id', '1004')` and,
for `/orders/1004`, `find(body.orders, 'id', path[1])` all find the order
whose `id` is `1004` or `"1004"`. When no element meets the value, the
call is missing, so `??` gives a fallback. `find` gives an element and
builds nothing, so the 1 MiB bound on a helper's result does not apply;
the bound on the rendered body still does.

```yaml
response:
  status: 200
  template: true
  json: "${find(body.items, 'sku', query.sku) ?? 'no such item'}"
```

`?sku=42` with the body `{"items":[{"sku":7,"qty":3},{"sku":42,"qty":1}]}`
gets `{"sku":42,"qty":1}`, and `?sku=5` gets `"no such item"`.

`last` gives the last element of an array, and steps can follow it, as
they follow any call. An empty array gives a missing value, so `??` gives
a fallback. A value that is not an array is an error. Like `find`, `last`
gives an element and builds nothing.

```yaml
response:
  status: 200
  template: true
  json:
    answer: It is ${last(body.messages).content ?? 'unknown'} in Paris.
```

The body
`{"messages":[{"role":"user","content":"Weather?"},{"role":"tool","content":"18 °C"}]}`
gets `{"answer":"It is 18 °C in Paris."}`, and `{"messages":[]}` gets
`{"answer":"It is unknown in Paris."}`.

A response reads the Data buckets after its own Stub's writes ([When data is
written](data-buckets.md#when-data-is-written)). So `last` answers the item
that the Stub's `append` just added to a keyed bucket, its [new
key](data-buckets.md#new-keys) included:

```yaml
- id: add-order
  mock: shop
  request: { method: POST, path: /api/v1/orders }
  dataWrites:
    - { op: append, bucket: orders, value: "${body}" }
  response:
    status: 201
    template: true
    headers: { Location: "/api/v1/orders/${last(data.orders).id}" }
    json: "${last(data.orders)}"
```

With the orders 1001 to 1003 keyed by `id`, `POST /api/v1/orders` with
the body `{"status":"new"}` gets `Location: /api/v1/orders/1004` and
`{"status":"new","id":1004}`. The next one in the same Session gets 1005.

## Encodings

Each argument may be any expression.

| Helper | Arguments | Output |
|---|---|---|
| `base64(s)` | text | The UTF-8 bytes of `s` in base64, with `=` padding. |
| `base64url(s)` | text | The same in base64url, the URL-safe alphabet, without padding. |
| `base64Decode(s)`, `base64urlDecode(s)` | text | The bytes that `s` encodes in base64, or in base64url, as text. |
| `urlEncode(s)` | text | The UTF-8 bytes of `s` percent-encoded, as RFC 3986 says, with upper-case hex digits. Only `A-Z a-z 0-9 - . _ ~` stay as they are, so a space becomes `%20`. |
| `urlDecode(s)` | text | `s` with each percent-escape decoded. `+` stays `+`. |

The decoders are strict, so a malformed input is an error, not a partial
result:

- `base64Decode` takes only the standard alphabet, `A-Z a-z 0-9 + /`, and
  `base64urlDecode` only the URL-safe one, `A-Z a-z 0-9 - _`. Any other
  character, whitespace included, is an error.
- Padding may be left out. Padding that is given must be complete and at
  the end: `Zg==` and `Zg` both give `f`, but `Zg=`, `Zg===` and `Zg==Zg==`
  are errors. Bits after the last byte are ignored.
- In `urlDecode`, a `%` that two hex digits, in either case, do not follow
  is an error.
- Decoded bytes that are not UTF-8 become U+FFFD, as in `bodyText`.

```yaml
response:
  status: 200
  template: true
  headers:
    Location: /search?q=${urlEncode(query.q)}
  json:
    token: ${base64url(query.token)}
    basic: ${base64(concat(body.user, ':', body.password))}
    text: ${base64Decode(body.data)}
```

`?q=a%20b%26c&token=a%2Bb` with the body
`{"user":"ann","password":"pw","data":"aGk="}` gets
`Location: /search?q=a%20b%26c` and
`{"token":"YSti","basic":"YW5uOnB3","text":"hi"}`.

## JWTs

The argument may be any expression.

| Helper | Arguments | Output |
|---|---|---|
| `jwtPayload(token)`, `jwtHeader(token)` | text | The payload, or the header, of the JWT `token`, as a JSON object. Read a claim with a step, such as `jwtPayload(header.authorization).sub`. |

- smock only decodes the token. It never checks the signature, the `alg`
  or a claim such as `exp`, so it reads an unsigned or forged token like
  any other. Never rely on a Mock to verify tokens.
- A leading `Bearer`, in any case, is removed when spaces or tabs follow
  it, and they go with it. So `header.authorization` can be passed as it
  is.
- A token is a JWS in compact form: three base64url parts separated by
  `.`, padding optional, the first two each the UTF-8 of a JSON object.
  The third part, the signature, may be empty.
- Anything else is missing, so `??` gives a fallback: no token, a
  malformed one, wrong padding (an error in `base64urlDecode`), a JWE of
  five parts, or a value that is not text.
- A member name that repeats keeps its last value, as RFC 7519 allows for
  claims.

```yaml
response:
  status: 200
  template: true
  json:
    user: ${jwtPayload(header.authorization).sub ?? 'anonymous'}
    alg: ${jwtHeader(header.authorization).alg ?? null}
```

With
`Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1LTQyIn0.c2ln`,
whose payload is `{"sub":"u-42"}`, the body is
`{"user":"u-42","alg":"HS256"}`. Without the header, or with a malformed
token, it is `{"user":"anonymous","alg":null}`.

## Dates

The date may be any expression. The format, the offset and the
duration are string literals.

| Helper | Arguments | Output |
|---|---|---|
| `dateFormat(date, format, offset)` | a date; a format; an offset, by default `Z` | `date` at `offset`, written in `format`. |
| `dateTimeShift(date, duration)` | a date; a duration | `date` shifted by `duration`, RFC 3339 in UTC with milliseconds, as `now()` writes it. |

- A date is an RFC 3339 date-time with an offset, such as
  `2026-01-31T19:00:00+09:00`; a date `YYYY-MM-DD`, read as midnight in
  UTC; or a number without a fraction, read as milliseconds since the Unix
  epoch, such as `nowMillis()` gives. A date is an instant: the offset it
  was written with is not kept.
- Anything else is missing, so `??` gives a fallback: a date-time without
  an offset, a date that does not exist, such as `2026-02-30`, a number
  with a fraction, or a string of digits. Write `number(query.ts)` to read
  milliseconds from the query. A literal that is not a date is an error
  when the files are loaded.
- An offset is `Z`, or `+HH:MM` or `-HH:MM` with `HH` up to 23 and `MM` up
  to 59, as RFC 3339 writes one. There are no time-zone names and no local
  time.
- A duration is an ISO 8601 duration with an optional sign, such as `P1M`,
  `-P2D`, `PT90M` or `P1Y2M3DT4H5M6S`: `P`, then years `Y`, months `M` and
  days `D`, then `T`, hours `H`, minutes `M` and seconds `S`. Each amount
  is optional, a whole number of at most 9 digits, in that order. Weeks
  (`W`) and fractions are errors when the files are loaded.
- A shift applies years and months first, on the UTC calendar. When the
  day does not exist in the month it reaches, it is that month's last day,
  so January 31 plus `P1M` is February 28, or 29 in a leap year. Then it
  applies days, then hours, minutes and seconds.
- A date, or a time that a date helper writes, outside the years 0 to 9999
  is an error when the template is rendered. `dateFormat` checks the date
  at its offset too.

A format uses date-fns tokens, as Mockoon's are, so most Mockoon formats
carry over:

| Token | Writes | At 2026-03-05T14:07:08.045Z |
|---|---|---|
| `yyyy`, `yy` | The year in four digits, or its last two. | `2026`, `26` |
| `M`, `MM`, `MMM`, `MMMM` | The month: its number, with a leading zero, or its short or full name. | `3`, `03`, `Mar`, `March` |
| `d`, `dd` | The day of the month. | `5`, `05` |
| `EEE`, `EEEE` | The day of the week, short or full. | `Thu`, `Thursday` |
| `H`, `HH` | The hour from 0 to 23. | `14`, `14` |
| `h`, `hh`, `a` | The hour from 1 to 12, and `AM` or `PM`. | `2`, `02`, `PM` |
| `m`, `mm`, `s`, `ss` | Minutes and seconds. | `7`, `07`, `8`, `08` |
| `S`, `SS`, `SSS` | Tenths, hundredths or milliseconds of the second. | `0`, `04`, `045` |
| `X`, `XX`, `XXX` | The offset: `Z` when it is zero, otherwise `+09` (`+0530` when the minutes are not zero), `+0900` or `+09:00`. | `Z`, `Z`, `Z` |
| `x`, `xx`, `xxx` | The same, with `+00`, `+0000` or `+00:00` when it is zero. | `+00`, `+0000`, `+00:00` |
| `t`, `T` | Seconds, or milliseconds, since the Unix epoch. | `1772719628`, `1772719628045` |
| `'…'`, `''` | The text between the quotes as it is, and one quote. | |

- Names are in English only, so no output depends on a locale.
- Characters that are not ASCII letters are written as they are. Quote
  letters to write them: unquoted, `T` writes milliseconds and `at` is `a`
  then `t`, so write `'T'` and `'at'`.
- `YYYY`, `YY` and `Y` (the week-numbering year) and `D` and `DD` (the day
  of the year) are errors when the files are loaded, so they never write a
  wrong date at the turn of a year: write `yyyy` and `dd`. So is any other
  unquoted ASCII letter, a run of a letter of a length the table does not
  list, such as `yyy`, and a quote that is not closed.
- `yyyy` and `yy` write the calendar year, so the year 0 is `0000` and
  `00`, as smock writes it in RFC 3339 times. date-fns writes the year of
  the era there instead: `0001`, for 1 BC.

```yaml
response:
  status: 200
  template: true
  json:
    today: ${now('yyyy-MM-dd')}
    due: ${dateFormat(dateTimeShift(now(), 'P1M'), 'yyyy-MM-dd', '+09:00')}
    issued: ${dateFormat(query.issued ?? now(), "EEE, d MMM yyyy 'at' HH:mm XXX", '+09:00')}
```

A request received at 2026-01-31T10:00:00Z with
`?issued=2026-03-05T14:07:08Z` gets
`{"today":"2026-01-31","due":"2026-02-28","issued":"Thu, 5 Mar 2026 at 23:07 +09:00"}`.

## How helpers read their arguments

The string helpers, and the families added after them, read their
arguments by one set of rules:

- A text argument is a string. A number or a boolean is taken as its text,
  a number written as in `json`. Null, an object or an array is an error.
- A numeric argument is a number, or a string that is a JSON number, as
  `number(x)` reads it. An integer argument is a numeric one without a
  fraction, so `6`, `6.0` and `'6'` are all 6. An integer too large to
  hold, such as `1e300`, is out of range, so as a position it clamps as
  other positions do.
- A value of the wrong kind from the request is an error when the template
  is rendered; the JWT helpers, and the date helpers for a date, give a
  missing value instead. A literal of the wrong kind, such as
  `padStart(query.n, 'six')` or `concat(null, 'a')`, is an error when the
  files are loaded, and so is a literal alternative of a fallback, such as
  the `true` of `padStart(query.n, query.width ?? true)`.
- A helper's result may take at most 1 MiB of UTF-8, an array or an object
  counted as its compact JSON. A larger one is an error, found before it is
  built. This is on top of the 1 MiB bound on a rendered body.

## Arithmetic

Each argument may be any expression, except the `places`
of `toFixed`. Each helper takes a fixed number of arguments, so nest calls
for more operands, as in `add(add(a, b), c)`. The arithmetic is exact in
decimal and uses integers only, so `add(0.1, 0.2)` is `0.3`, and every
result is the same on native and on wasm-gc.

| Helper | Arguments | Output |
|---|---|---|
| `add(a, b)`, `subtract(a, b)`, `multiply(a, b)` | numbers | `a + b`, `a - b` or `a × b`, exact. |
| `divide(a, b)` | numbers; `b` not 0 | `a ÷ b`, rounded half to even at 10 decimal places: `divide(10, 3)` is `3.3333333333`, and `divide(1, 2048)`, which is 0.00048828125, is `0.0004882812`. |
| `modulo(a, b)` | numbers; `b` not 0 | The remainder of `a ÷ b` truncated toward zero, so it has the sign of `a`, as JavaScript's `%` does: `modulo(-7, 3)` is `-1`. |
| `ceil(x)`, `floor(x)` | a number | The nearest integer toward +∞, or toward −∞. |
| `round(x)` | a number | The nearest integer, half away from zero: `round(2.5)` is `3` and `round(-2.5)` is `-3`. |
| `toFixed(x, places)` | a number; an integer literal from 0 to 18 | `x` rounded half away from zero to `places` decimals, and written with exactly that many, as `fake.decimal` writes its numbers: `toFixed(1.005, 2)` is `1.01`, and `toFixed(19.99, 3)` is `19.990`. |
| `parseInt(x)` | a number | The integer part of `x`, truncated toward zero: `parseInt(-12.7)` is `-12`. |

```yaml
response:
  status: 200
  template: true
  json:
    total: ${multiply(body.price, body.qty)}
    next: ${add(query.page ?? 1, 1)}
    third: ${divide(10, 3)}
    price: ${toFixed(body.price, 3)}
```

`?page=4` with the body `{"price":19.99,"qty":3}` gets
`{"total":59.97,"next":5,"third":3.3333333333,"price":19.990}`.

- A numeric argument is read as a decimal. A number is taken as smock
  writes it in `json`: the text it kept, such as the digits of an integer
  beyond 2^53 or the output of `fake.decimal`, otherwise the shortest form
  that reads back as the same 64-bit float. So `19.99` is 19.99, not the
  float nearest to it. A string that is a JSON number is taken as its own
  text, so `add('0.10', 1)` is `1.1`.
- A number literal in an argument is taken as written, with every digit,
  even those a 64-bit float would lose: `add(0.123456789012345678, 0)` is
  `0.123456789012345678`, and `add(0.12345678901234567891, 0)`, with 20
  digits after the point, is an error when the files are loaded. How a
  literal is written anywhere else does not change:
  `${0.123456789012345678}` alone still writes `0.12345678901234568`, as
  `json` would.
- Numbers have at most 18 digits before the point and 18 after. Zeros
  before the first digit that is not 0, and after the last one, do not
  count, so `'1.000000000000000000000'` is 1. An argument beyond the bounds
  is an error, found when the files are loaded for a literal. A result
  beyond them is an error too: `multiply` never rounds, so
  `multiply('0.000000001', '0.0000000001')` is an error, not 0. Within the
  bounds, integers keep every digit: there is no rounding at 2^53.
- A result is a number, written as a plain decimal with no exponent and no
  trailing zeros: `add(1.50, 1)` is `2.5`, `divide(1, 10000000)` is
  `0.0000001`, and zero is `0`, never `-0`. `toFixed` keeps exactly
  `places` decimals instead, and writes `toFixed(-0.001, 2)` as `0.00`.
- Other helpers and conditions take a result as a number, so
  `padStart(s, add(n, 1))`, `range(1, add(n, 1))` and
  `$if: add(a, b) == 3` all work. Where an integer is taken, a result is
  the decimal it writes, so one with a fraction is not an integer, however
  small: `substr(s, add(1, '0.000000000000000001'))` is an error.
- A zero divisor of `divide` or `modulo`, even a literal 0, is an error
  when the template is rendered.

None of these helpers draws from the random source.

## The random source and the time of a request

The word and name lists are part of format version 1. A matched request
takes exactly one 64-bit output from its Stub's random source (its own
generator with `fault.seed`, otherwise the process generator, see
[Seeds](faults.md#seeds)), whatever its template draws: the Fault decisions
draw from a generator seeded with it, the pick among
[`responses`](responses.md#several-responses) from another one seeded with
it XOR a fixed constant, and the helpers from a third one seeded with it XOR
another constant, in render order (header values in the order written, an
array's values in order, then the body, members and loop iterations in
order, or the events in order, each event's `event`, `id`, then `data` or
`json`). So a seeded Stub repeats its helper output on every run, on native
and on wasm-gc alike, and adding fake data never changes its Faults or its
picks.

`now()`, `now(format)` and `nowMillis()` read the time smock received the
request at, never the clock while rendering; in an event, they add the
delays of the events up to and including it:

```yaml
response:
  status: 200
  template: true
  headers: { Cache-Control: no-cache }
  events:
    - { event: price, id: "1", json: { symbol: "${query.symbol}", price: "${fake.decimal(90, 110, 2)}", at: "${now()}" } }
    - { delay: 500, event: price, id: "2", json: { symbol: "${query.symbol}", price: "${fake.decimal(90, 110, 2)}", at: "${now()}" } }
    - { delay: 500, data: "[DONE]" }
fault: { seed: 7 }
```

The last event is `data: [DONE]` alone, the frame that ends an OpenAI Chat
Completions stream, which has no `event:` line. To stand in for an LLM API,
an [LLM response](llm-responses.md#llm-responses) writes the reply in the
API's wire form, so no event needs writing by hand.
