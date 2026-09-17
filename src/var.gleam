import gleam/erlang/process.{type Pid, type Subject}
import gleam/otp/actor.{type Next, type StartError, type Started, Started}
import gleam/result

import error.{type Exception}

/// 要与可变值交互需要持有此类型
pub opaque type Var(var) {
  Var(sub: Subject(MSG(var)), pid: Pid)
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
  Update(update: fn(var) -> var, sub: Subject(Result(var, UpdateError)))
}

/// 属于[scope](https://variable.hexdocs.pm/var.html#scope)函数的错误类型
pub type ScopeError {
  /// 进程启动失败
  StartErr(err: StartError)
  /// 回调函数异常
  ScopeErr(err: Exception)
}

/// 属于[update](https://variable.hexdocs.pm/var.html#update)函数的错误类型
pub type UpdateError {
  /// 回调函数异常
  UpdateErr(err: Exception)
}

/// 属于[try_get](https://variable.hexdocs.pm/var.html#try_get)/[try_set](https://variable.hexdocs.pm/var.html#try_set)函数的错误类型
pub type Timeout {
  /// 超时
  Timeout
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
/// val：初始值
/// 
/// scope：一个接受可变值([Var](https://variable.hexdocs.pm/var.html#Var))作为参数的函数
pub fn scope(
  val: var,
  scope: fn(Var(var)) -> reason,
) -> Result(reason, ScopeError) {
  // 初始化可变值
  init(val)
  // 包装传入的函数
  |> fn(var: Result(Var(var), StartError)) -> Result(reason, ScopeError) {
    case var {
      // 启动失败
      Error(err) -> Error(StartErr(err))
      // 启动成功
      Ok(var) -> {
        // 使用try函数运行回调函数
        let result = error.try(fn() { scope(var) })
        // 无论回调是否异常都终止进程
        kill(var)

        // 回调正常返回其返回值
        use err <- result.try_recover(result)
        // 回调异常返回错误
        Error(ScopeErr(err))
      }
    }
  }()
}

/// 在指定时间内(毫秒)获取值
/// 
/// 操作可能超时，可以使用[try_get](https://variable.hexdocs.pm/var.html#try_get)
/// 
/// 如果想一直等待可以使用[get_forever](https://variable.hexdocs.pm/var.html#get_forever)
pub fn get(var: Var(var), timeout: Int) -> var {
  process.call(var.sub, timeout, Get)
}

/// 获取值并一直等待直至成功
pub fn get_forever(var: Var(var)) -> var {
  process.call_forever(var.sub, Get)
}

/// 尝试在指定时间内(毫秒)获取值
pub fn try_get(var: Var(var), timeout: Int) -> Result(var, Timeout) {
  fn() { process.call(var.sub, timeout, Get) }
  |> error.try()
  |> result.try_recover(fn(_) { Error(Timeout) })
}

/// 在指定时间内(毫秒)设置值，随后后返回新的值
/// 
/// 操作可能超时，可以使用[try_set](https://variable.hexdocs.pm/var.html#try_set)
/// 
/// 如果想一直等待可以使用[set_forever](https://variable.hexdocs.pm/var.html#set_forever)
pub fn set(var: Var(var), timeout: Int, new_val: var) -> var {
  process.call(var.sub, timeout, Set(new_val:, sub: _))
}

/// 设置值并一直等待直至成功，随后返回新的值
pub fn set_forever(var: Var(var), new_val: var) -> var {
  process.call_forever(var.sub, Set(new_val:, sub: _))
}

/// 尝试在指定时间内(毫秒)设置值，随后返回新的值
pub fn try_set(
  var: Var(var),
  timeout: Int,
  new_val: var,
) -> Result(var, Timeout) {
  fn() { process.call(var.sub, timeout, Set(new_val:, sub: _)) }
  |> error.try()
  |> result.try_recover(fn(_) { Error(Timeout) })
}

/// 使用函数更新值，随后返回更新后的值
/// 
/// 若函数异常则保持原有值不变
/// 
/// # Notice
/// 该函数没有超时保护，会一直等待直至回调函数返回或异常
/// 
/// 如果回调函数卡住则会造成阻塞，导致其他操作超时
pub fn update(
  var: Var(var),
  update: fn(var) -> var,
) -> Result(var, UpdateError) {
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
fn init(val: var) -> Result(Var(var), StartError) {
  use Started(data:, pid:) <- result.try(new(val))
  Var(data, pid) |> Ok()
}

/// 创建新的可变值进程
fn new(val: var) -> Result(Started(Subject(MSG(var))), StartError) {
  actor.new(val)
  |> actor.on_message(handle)
  |> actor.start()
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
        // 函数正常
        Ok(new_val) -> {
          process.send(sub, Ok(new_val))
          actor.continue(new_val)
        }
        // 函数异常
        Error(err) -> {
          process.send(sub, Error(UpdateErr(err)))
          actor.continue(val)
        }
      }
  }
}
