// The testee of yaml-test-suite (README.md): for each case it is given, it
// reads the case's input, `in.yaml`, from the suite's directory, and prints
// its answer (testee.mbt), one line for each case, in the order given.
// scripts/check-yaml-test-suite.sh starts it with every case of the suite.

///|
/// Ends the process with `code`, through `moonbitlang/x`'s supported exit,
/// as cmd/smock does.
fn exit(code : Int32) -> Unit {
  @sys.exit(code)
}

///|
async fn main {
  let args = @env.args()
  guard args.length() >= 2 else {
    eprintln("usage: yaml-test-suite <suite directory> [<case>...]")
    exit(2)
    return
  }
  for name in args[2:] {
    let path = "\{args[1]}/\{name}/in.yaml"
    let input = @fs.read_file(path).binary() catch {
      error => {
        eprintln("yaml-test-suite: \{path}: \{error}")
        exit(1)
        return
      }
    }
    println(answer(name, input))
  }
}
