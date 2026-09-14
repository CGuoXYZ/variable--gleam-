# variable

使用otp进程模拟的可变值

gleam推荐以不变性优先，建议只在确实需要可变性时才使用

[![Package Version](https://img.shields.io/hexpm/v/variable)](https://hex.pm/packages/variable)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://variable.hexdocs.pm/)

```sh
gleam add variable
```
```gleam
import var

pub fn main() {
    use val <- var.scope(5, 1000)
    // ...
}
```

## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests
```
