import gleam/bool
import gleam/erlang/process.{type Pid, type Subject}
import gleam/otp/actor.{type Next, type StartError, type Started, Started}
import gleam/result

import error.{type Exception}

const default_restart = 3

/// 要与可变值交互需要持有此类型
pub opaque type Var(var) {
  Var(sub: Subject(MSG(var)), pid: Pid, time_out: Int)
}

/// 可变值进程接收的消息
type MSG(var) {
  /// 销毁
  Kill
  /// 获取值
  Get(sub: Subject(var))
  /// 设置值
  Set(new_val: var, sub: Subject(var))
  /// 使用给定函数处理值
  Update(update: fn(var) -> var, sub: Subject(Result(var, CallbackError)))
}

/// 属于[scope](https://variable.hexdocs.pm/var.html#scope)函数的错误类型
pub type ScopeError {
  /// 进程启动失败
  StartErr(err: StartError)
  /// 回调函数异常
  CallbackErr(err: Exception)
}

/// 属于 try_* 函数的错误类型
pub type Timeout {
  /// 超时
  Timeout
}

/// 属于[update](https://variable.hexdocs.pm/var.html#update)函数的错误类型
pub type CallbackError {
  /// 回调函数异常
  CallbackError(err: Exception)
}

/// 创建一个进程模拟可变值
/// 
/// 可变值在回调函数中可用，函数结束自动销毁
/// 
/// # Notice
/// 如果回调函数已经结束，但仍有进程在持有可变值则有引发异常的风险
/// 
/// 对于可变值出逃后的行为不作保障
/// 
/// # Param
/// init_val：初始值
/// 
/// time_out：作为有超时保护的函数的超时上限(毫秒)
/// 
/// scope_fn：一个接受可变值([Var](https://variable.hexdocs.pm/var.html#Var))作为参数的函数
pub fn scope(
  init_val: var,
  time_out: Int,
  scope_fn: fn(Var(var)) -> reason,
) -> Result(reason, ScopeError) {
  // 初始化可变值
  init(init_val, time_out)
  // 包装传入的函数
  |> fn(var: Result(Var(var), StartError)) -> Result(reason, ScopeError) {
    case var {
      // 启动失败
      Error(err) -> Error(StartErr(err))
      // 启动成功
      Ok(var) -> {
        // 使用try函数运行回调函数
        let result = error.try(fn() { scope_fn(var) })

        // 无论回调是否异常都终止进程
        kill(var)

        // 回调正常返回其返回值
        use err <- result.try_recover(result)
        // 回调异常返回错误
        Error(CallbackErr(err))
      }
    }
  }()
}

/// 获取值
/// 
/// 操作可能超时，可以使用[try_get](https://variable.hexdocs.pm/var.html#try_get)
/// 
/// 如果想一直等待可以使用[get_forever](https://variable.hexdocs.pm/var.html#get_forever)
/// 
/// # Example
/// ```gleam
/// use val <- var.scope(5, 1000)
/// assert var.get(val) == 5
/// ```
pub fn get(var: Var(var)) -> var {
  process.call(var.sub, var.time_out, Get)
}

/// 获取值并一直等待直至成功
pub fn get_forever(var: Var(var)) -> var {
  process.call_forever(var.sub, Get)
}

/// 尝试获取值
pub fn try_get(var: Var(var)) -> Result(var, Timeout) {
  fn() { process.call(var.sub, var.time_out, Get) }
  |> error.try()
  |> result.try_recover(fn(_) { Error(Timeout) })
}

/// 设置值，随后后返回新的值
/// 
/// 操作可能超时，可以使用[try_set](https://variable.hexdocs.pm/var.html#try_set)
/// 
/// 如果想一直等待可以使用[set_forever](https://variable.hexdocs.pm/var.html#set_forever)
/// 
/// # Example
/// ```gleam
/// use val <- var.scope(5, 1000)
/// assert var.get(val) == 5
/// assert var.set(val, 10) == 10
/// assert var.get(val) == 10
/// ```
pub fn set(var: Var(var), new_val: var) -> var {
  process.call(var.sub, var.time_out, Set(new_val:, sub: _))
}

/// 设置值并一直等待直至成功，随后返回新的值
pub fn set_forever(var: Var(var), new_val: var) -> var {
  process.call_forever(var.sub, Set(new_val:, sub: _))
}

/// 尝试设置值并返回新的值
pub fn try_set(var: Var(var), new_val: var) -> Result(var, Timeout) {
  fn() { process.call(var.sub, var.time_out, Set(new_val:, sub: _)) }
  |> error.try()
  |> result.try_recover(fn(_) { Error(Timeout) })
}

/// 使用函数更新值，随后返回更新后的值
/// 
/// 若函数异常则保持原有值不变
/// 
/// # Notice
/// 该函数没有超时保护，它会一直等待，直至回调函数返回或异常
/// 
/// 若回调函数卡住则会造成阻塞，导致其它操作超时
/// 
/// # Example
/// ```gleam
/// use val <- var.scope(5, 1000)
/// assert var.update(val, fn(v) { { v + 1 } * 2 }) == Ok(12)
/// var.update(val, fn(_) { panic }) // Error(..)
/// assert var.get(val) == 12
/// ```
pub fn update(
  var: Var(var),
  update: fn(var) -> var,
) -> Result(var, CallbackError) {
  process.call_forever(var.sub, Update(update:, sub: _))
}

/// 检查可变值是否存活
/// 
/// 该函数主要用在可变值疑似出逃的情景，使用前可以进行检查
/// 
/// # Notice
/// 不要过度相信这个结果，因为值可能前脚还存活后脚就被销毁了
pub fn is_alive(var: Var(var)) -> Bool {
  process.is_alive(var.pid)
}

/// 销毁值
fn kill(var: Var(var)) {
  process.send(var.sub, Kill)
}

/// 初始化新的可变值
fn init(val: var, time_out: Int) -> Result(Var(var), StartError) {
  // 尝试启动
  use Started(data:, pid:) <- result.try(new(val))
  Var(data, pid, time_out) |> Ok()
}

/// 创建新的可变值
/// 
/// 默认重试 default_restart 次，直至成功
fn new(val: var) -> Result(Started(Subject(MSG(var))), StartError) {
  // 尝试启动三次
  use <- restart(default_restart)
  actor.new(val)
  |> actor.on_message(handle)
  |> actor.start()
}

/// 多次运行函数，直至其返回 Ok
fn restart(n: Int, f: fn() -> Result(ok, err)) -> Result(ok, err) {
  case f() {
    Ok(ok) -> Ok(ok)
    Error(err) -> bool.guard(n == 1, Error(err), fn() { restart(n - 1, f) })
  }
}

fn handle(val: var, msg: MSG(var)) -> Next(var, MSG(var)) {
  case msg {
    // 销毁
    Kill -> actor.stop()
    // 获取值
    Get(sub:) -> {
      process.send(sub, val)
      actor.continue(val)
    }
    // 设置值
    Set(new_val:, sub:) -> {
      process.send(sub, new_val)
      actor.continue(new_val)
    }
    // 使用给定函数更新值
    Update(update:, sub:) ->
      case error.try(fn() { update(val) }) {
        // 函数正常返回结果
        Ok(new_val) -> {
          process.send(sub, Ok(new_val))
          actor.continue(new_val)
        }
        // 函数异常
        Error(err) -> {
          process.send(sub, Error(CallbackError(err)))
          actor.continue(val)
        }
      }
  }
}
