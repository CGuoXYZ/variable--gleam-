# variable

使用OTP进程模拟的可变值，提供临时的可变值

Gleam推荐以不变性优先，**建议只在确实需要时才考虑使用**

只支持**Erlang**端

[![Package Version](https://img.shields.io/hexpm/v/variable)](https://hex.pm/packages/variable)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://variable.hexdocs.pm/)

```sh
gleam add variable
```

## Example
用`scope`函数创建可变值，回调结束时它会被自动销毁

每个`Var`对应一个进程，读写靠消息传递
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

## subscribe
订阅函数，在值变化时收到旧值和新值
```gleam
use val <- var.scope(10)

assert var.get(val, 1000) == 10

// 订阅函数并获取用于取消订阅的函数
let unsubscribe =
  var.subscribe(val, fn(old, new) {
    io.println(int.to_string(old) <> " -> " <> int.to_string(new))
  })

// 设置新值，订阅函数收到 旧值10 和 新值4
assert var.set(val, 1000, 4) == 4

// 取消订阅
unsubscribe()

// 设置新值，没有订阅函数收到消息
assert var.set(val, 1000, 5) == 5
```
在订阅函数中`set`/`update`同一个`Var`会导致循环
```gleam
use val <- var.scope(5)

var.subscribe(val, fn(old, new) {
  io.println(int.to_string(old) <> " -> " <> int.to_string(new))
  var.set(val, 1000, new + 1)
})

var.set(val, 1000, 6)
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
`scope`回调结束时会自动终止进程。如果`Var`被传到了回调外面，之后再用它会 panic

可以用`is_alive`函数做防御性检查
```gleam
case var.is_alive(val) {
  True -> var.get(val, 1000)
  False -> 0
}
```
