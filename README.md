# variable

使用OTP进程模拟的可变值

Gleam推荐以不变性优先，**建议只在确实需要可变性时才使用**，每个`Var`对应一个进程，读写靠消息传递

只支持Erlang端

[![Package Version](https://img.shields.io/hexpm/v/variable)](https://hex.pm/packages/variable)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://variable.hexdocs.pm/)

```sh
gleam add variable
```

## Example

用`scope`函数创建可变值，回调结束时它会被自动销毁：

```gleam
import var

pub fn main() -> Result(Nil, var.ScopeError) {
  use val <- var.scope(0)

  // 读取：在指定毫秒内获取值，超时会panic
  assert var.get(val, 1000) == 0

  // 设置：在指定毫秒内设置并返回新的值，超时会panic
  assert var.set(val, 1000, 10) == 10

  // 更新：给定函数更新值，函数异常则值保持不变
  assert var.update(val, fn(n) { n * 2 }) == Ok(20)

  assert var.get(val, 1000) == 20

  Nil
}
```

## Error

```gleam
// scope：进程启动失败 | 回调函数异常
case var.scope(0, fn(val) { var.get(val, 1000) }) {
  Ok(result) -> // 回调正常结束返回的值
  Error(var.StartErr(err)) -> // 进程启动失败
  Error(var.ScopeErr(err)) -> // 回调函数异常
}

// try_get / try_set：超时
case var.try_set(val, 100, 10) {
  Ok(new_val) -> // 设置成功，返回新值
  Error(var.Timeout) -> // 超时
}

// update：回调函数异常
case var.update(val, fn(n) { n + 1 }) {
  Ok(new_val) -> // 更新成功
  Error(var.UpdateErr(err)) -> // 回调函数异常，值保持不变
}
```

回调异常的错误类型来自[`shine_try.Exception`](https://hexdocs.pm/shine_try/error.html#Exception)，只包含原始的 `class` / `reason` / `stacktrace`，可自行解析

## `Var` escape

`scope`的回调结束时会自动终止进程。如果`Var`被传到了回调外面，之后再用它会 panic，可以用`is_alive`函数做防御性检查：

```gleam
case var.is_alive(val) {
  True -> var.get(val, 1000)
  False -> 0
}
```

## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests
```
