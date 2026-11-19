# The e2e coverage report's test data

scripts/test-coverage-e2e.sh runs scripts/coverage-e2e.py on these files.

- `tree/` is a small module's source: `server` and `cmd/smock`, whose
  positions the report decides, `watch`, whose unreached points it lists
  as it lists `server`'s, and `prng`, whose points it counts but does not
  list. It has no `moon.pkg`, so moon builds none of it from the
  repository's root.
- `trees/` holds the pinned compiler's parse trees of the `server` and
  `cmd/smock` files, as the site finder writes them
  (`moonc compile -dsource -show-loc -target wasm-gc`), so that the test
  needs no compiler.
- `in-process.bisect` and `e2e.bisect` are bisect reports of format 4
  over that tree. Their points are where the compiler put them when the
  tree was built with coverage; their counts are set by hand:

| point | what starts there | in-process | e2e |
|---|---|---:|---:|
| `server/serve.mbt:12:3` | `Server::new`'s body | 1 | 1 |
| `server/serve.mbt:18:3` | `Server::serve`'s body | 1 | 2 |
| `server/serve.mbt:18:27` | the guard's else | 0 | 0 |
| `server/serve.mbt:19:3` | what follows the guard | 1 | 2 |
| `server/serve.mbt:20:5` | the then of `path == "/"` | 1 | 0 |
| `server/serve.mbt:22:5` | its else | 0 | 2 |
| `server/serve.mbt:24:9` | the value matched | 1 | 2 |
| `server/serve.mbt:24:14` | the call of `length` | 1 | 2 |
| `server/serve.mbt:25:10` | the arm `0` | 0 | 0 |
| `server/serve.mbt:26:10` | the arm `n` | 1 | 2 |
| `server/serve.mbt:33:3` | `Server::stop`'s body | 0 | 1 |
| `server/serve.mbt:34:5` | the then of `force` | 0 | 0 |
| `server/serve.mbt:37:5` | the body of the while loop | 0 | 0 |
| `server/serve.mbt:45:3` | `Server::unused`'s body | 0 | 0 |
| `watch/watch.mbt:4:3` | `changed`'s body | 1 | 2 |
| `watch/watch.mbt:5:5` | its then | 0 | 0 |
| `watch/watch.mbt:7:5` | its else | 1 | 2 |
| `prng/prng.mbt:4:3` | `next`'s body | 0 | 1 |
| `prng/prng.mbt:5:5` | its then | 0 | 0 |
| `prng/prng.mbt:7:5` | its else | 0 | 1 |
| `cmd/smock/main.mbt:5:3` | `main`'s body | 0 | 1 |
| `cmd/smock/main.mbt:5:16` | the call of `Server::new` | 0 | 1 |
| `cmd/smock/main.mbt:6:35` | the closure `answer`'s body | 0 | 1 |
| `cmd/smock/main.mbt:6:42` | its call of `serve` | 0 | 1 |
| `cmd/smock/main.mbt:7:41` | the closure `unused_handler`'s body | 0 | 0 |
| `cmd/smock/main.mbt:8:3` | the first `ignore` | 0 | 1 |
| `cmd/smock/main.mbt:8:10` | the call of `answer` | 0 | 1 |
| `cmd/smock/main.mbt:9:3` | the second `ignore` | 0 | 1 |
| `cmd/smock/main.mbt:10:10` | the call of `stop` | 0 | 1 |

To make the trees again with the pinned compiler, run the site finder's
`dump` on each file (scripts/mutation/sites.py); to see where a newer
compiler puts the points, build the tree as a module with
`moon build --enable-coverage` and read its trace sources with moon_cove,
as scripts/coverage.sh does.
