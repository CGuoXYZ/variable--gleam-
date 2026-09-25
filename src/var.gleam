import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Selector, type Subject}
import gleam/erlang/reference.{type Reference}
import gleam/otp/actor.{type Next, type StartError, type Started, Started}
import gleam/result

import error.{type Exception}

/// 要与可变值交互需要持有此类型
pub opaque type Var(var) {
  Var(sub: Subject(ValMSG(var)), pid: Pid)
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

/// [subscribe](https://variable.hexdocs.pm/var.html#subscribe)函数返回的用于取消订阅的函数的返回值
pub opaque type Unsubscribed {
  /// 已取消订阅
  Unsubscribed
}

/// 可变值进程携带的状态
type Val(var) {
  /// val: 值本身
  /// 
  /// subscribe: 携带订阅进程通道的字典
  Val(val: var, subscribe: Dict(Reference, Subject(SubMSG(var))))
}

/// 可变值进程接收的消息
type ValMSG(var) {
  /// 关闭可变值进程
  ValClosure
  /// 订阅
  Subscribe(ref: Reference, sub: Subject(SubMSG(var)))
  /// 取消订阅
  Unsubscribe(ref: Reference)
  /// 获取值
  Get(sub: Subject(var))
  /// 设置值
  Set(new_val: var, sub: Subject(var))
  /// 使用给定函数处理值
  Update(update: fn(var) -> var, sub: Subject(Result(var, UpdateError)))
}

/// 订阅进程接收的消息
type SubMSG(var) {
  /// 关闭订阅进程
  SubClosure
  /// 可变值进程已关闭
  ValClosed
  /// 值变化
  ValChange(old_val: var, new_val: var)
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
  scope: fn(Var(var)) -> return,
) -> Result(return, ScopeError) {
  // 初始化可变值
  init(val)
  // 包装传入的函数
  |> fn(var: Result(Var(var), StartError)) -> Result(return, ScopeError) {
    case var {
      // 启动失败
      Error(err) -> Error(StartErr(err))
      // 启动成功
      Ok(var) -> {
        // 尝试执行回调函数
        //
        // 成功返回回调的返回值
        // 失败返回回调的异常
        use ex <- result.try_recover({
          // 尝试执行回调，随后关闭可变值进程
          use <- error.defer(fn() { closure(var) })
          use <- error.try()
          scope(var)
        })
        Error(ScopeErr(ex))
      }
    }
  }()
}

/// 订阅函数，每当成功[set](https://variable.hexdocs.pm/var.html#set)/[update](https://variable.hexdocs.pm/var.html#update)时自动调用订阅函数
/// 
/// 订阅函数发生异常不会有后果
/// 
/// 该函数会为每个订阅spawn一个进程，如果订阅函数执行的较慢则会导致消息堆积
/// 
/// # Param 
/// f: 接收旧值和新值的订阅函数(**f(old_val, new_val)**)
/// 
/// # Return
/// 返回一个用于取消订阅的函数
pub fn subscribe(
  var: Var(var),
  f: fn(var, var) -> discard,
) -> fn() -> Unsubscribed {
  // 用于接收订阅进程的通道
  let ready = process.new_subject()

  // 创建订阅进程
  process.spawn_unlinked(fn() {
    // 订阅进程的通道
    let sub = process.new_subject()
    // 监控可变值进程
    let mon = process.monitor(var.pid)
    // 选择器
    let sel =
      process.new_selector()
      |> process.select(sub)
      |> process.select_specific_monitor(mon, fn(_) { ValClosed })

    // 发送订阅进程的通道
    process.send(ready, sub)

    subscribe_pkg(sel, f)
  })

  // 唯一键
  let ref = reference.new()
  // 获取订阅进程的通道以用于发送值变化的消息
  let sub = process.receive_forever(ready)
  // 向可变值进程发送消息以注册订阅
  process.send(var.sub, Subscribe(ref:, sub:))

  // 返回用于取消订阅的函数
  fn() -> Unsubscribed {
    process.send(var.sub, Unsubscribe(ref:))
    Unsubscribed
  }
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
  fn() { get(var, timeout) }
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
  fn() { set(var, timeout, new_val) }
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

/// 关闭可变值进程
fn closure(var: Var(var)) {
  process.send(var.sub, ValClosure)
}

/// 初始化新的可变值
fn init(val: var) -> Result(Var(var), StartError) {
  use Started(data:, pid:) <- result.try(new(val))
  Var(data, pid) |> Ok()
}

/// 创建新的可变值进程
fn new(val: var) -> Result(Started(Subject(ValMSG(var))), StartError) {
  actor.new(Val(val:, subscribe: dict.new()))
  |> actor.on_message(handle)
  |> actor.start()
}

/// 包装订阅函数
fn subscribe_pkg(
  sel: Selector(SubMSG(var)),
  f: fn(var, var) -> discard,
) -> Nil {
  case process.selector_receive_forever(sel) {
    // 关闭消息或可变值进程关闭消息
    SubClosure | ValClosed -> Nil
    // 值变化消息
    ValChange(old_val:, new_val:) -> {
      error.try(fn() { f(old_val, new_val) }) |> discard()
      subscribe_pkg(sel, f)
    }
  }
}

/// 通知订阅函数值已发生变化
fn notify(
  subscribe: Dict(Reference, Subject(SubMSG(var))),
  old_val: var,
  new_val: var,
) {
  use _, sub <- dict.each(subscribe)
  process.send(sub, ValChange(old_val:, new_val:))
}

/// 用不到的值需要用 let _ = ... 消除警告
/// 
/// 可用这个函数替代
fn discard(_) {
  Nil
}

fn handle(val: Val(var), msg: ValMSG(var)) -> Next(Val(var), ValMSG(var)) {
  let Val(val:, subscribe:) = val

  case msg {
    // 关闭
    ValClosure -> actor.stop()
    // 订阅
    Subscribe(ref:, sub:) ->
      Val(val:, subscribe: dict.insert(subscribe, ref, sub))
      |> actor.continue()
    // 取消订阅
    Unsubscribe(ref:) -> {
      result.try(dict.get(subscribe, ref), fn(sub) {
        process.send(sub, SubClosure) |> Ok()
      })
      |> discard()

      Val(val:, subscribe: dict.delete(subscribe, ref))
      |> actor.continue()
    }
    // 获取值
    Get(sub:) -> {
      // 发送当前值
      process.send(sub, val)
      actor.continue(Val(val:, subscribe:))
    }
    // 设置值
    Set(new_val:, sub:) -> {
      // 发送新值
      process.send(sub, new_val)
      // 通知订阅函数值已发生变化
      notify(subscribe, val, new_val)
      actor.continue(Val(val: new_val, subscribe:))
    }
    // 使用给定函数更新值
    Update(update:, sub:) ->
      case error.try(fn() { update(val) }) {
        // 函数正常
        Ok(new_val) -> {
          // 发送新值
          process.send(sub, Ok(new_val))
          // 通知订阅函数值已发生变化
          notify(subscribe, val, new_val)
          actor.continue(Val(val: new_val, subscribe:))
        }
        // 函数异常
        Error(err) -> {
          // 发送回调异常
          process.send(sub, Error(UpdateErr(err)))
          actor.continue(Val(val:, subscribe:))
        }
      }
  }
}
