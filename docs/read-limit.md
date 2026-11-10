# maki.fs.read fails on a file over 1 GiB

maki 0.5.3. The /replay plugin hit this on a session file of 1,080,441,316 bytes.

## What happened

`maki.fs.read` did not return `nil` with an error message. It raised a Lua
runtime error, so the whole command failed:

```json
{"level":"WARN","fields":{"message":"command handler failed","plugin":"global/init.lua","command":"/replay","error":"runtime error: memory allocation error: block too big\nstack traceback:\n\t[C]: in ?\n\t[C]: in ?\n\t[C]: in ?\n\t__mlua_async_poll:28: in function <__mlua_async_poll:1>\n\t[string \"replay\"]:188: in function 'export'\n\t[string \"replay\"]:386: in function 'handler'"}}
```

The API reference names one failure that throws, which is non-UTF-8 content. It
names no size limit, so no plugin can plan for one.

## Cause

`maki-lua/src/api/fs.rs:100` returns the whole file as one Lua string. Luau caps
one string at `MAXSSIZE`, which is `1 << 30`
(`luau0-src-0.18.3+luau709/luau/VM/src/lstring.h:9`). `newlstr` raises
`luaM_toobig` past that length (`lstring.cpp:73`, message in `lmem.cpp:237`).
`read_bytes` shares the cap: `MAX_BUFFER_SIZE` in `lbuffer.h` is also `1 << 30`.

Session files pass 1 GiB in normal use. This one holds 23,250 records, and its
largest record is 6,907,730 bytes.

## No other API reads part of a file

There is no offset, no length, and no line iterator. Each alternative failed for
a named reason:

1. `maki.fs.read_bytes`: one buffer, so the same cap.
2. `maki.fn.jobstart` with `cat` and `on_stdout`: the reader thread sends every
   line into an unbounded channel (`api/fn.rs:318`). A fast child then put the
   whole file in memory on the Rust side.
3. `maki.fn.jobwait`: it joins every stdout line into one string
   (`api/fn.rs:1278`), so the child output must stay small in each call.
4. Raw byte windows: the reader splits on newlines and drops carriage returns
   (`api/fn.rs:327`).

## Workaround used

`plugin/init.lua` copies 8 MiB windows with
`dd if="$REPLAY_FILE" bs=%d skip=N count=1 status=none | base64 | tr -d '\n'`
and reassembles lines in Lua. `base64` keeps the bytes intact through a reader
that works on lines. `tr -d '\n'` keeps one event per window, and `tail = 0`
keeps the job store from holding 20 lines of it. The path travels only in `env`,
so a file name never becomes command text.

The workaround costs about 33 percent more bytes in transit and reads each file
twice. It also needs `dd`, `base64`, and `tr` on PATH, which is false on
Windows. Files under 64 MiB still use a single `maki.fs.read`.

The raw log line from that failure is [read-limit.log](read-limit.log).

## Ask

1. Make `read` answer with a size error instead of raising. A `metadata` length
   test before the read is enough, and plugins already handle `(nil, err)`.
2. Add `maki.fs.read_range(path, {offset, limit})`, or `maki.fs.lines(path,
   on_line)`. Either one removes this workaround.
3. Document the 1 GiB cap on `read` and `read_bytes`, and the fact that
   `jobwait` returns one string.
