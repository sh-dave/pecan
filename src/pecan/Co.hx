package pecan;

class Co<TIn, TOut> {
  public static macro function co(block, tin, tout):Expr {}
  public static macro function coDebug(block, tin, tout):Expr {}

  public final actions:Array<CoAction<TIn, TOut>>;
  public final labels:Map<String, Int>;
  public final vars:CoVariables;
  public var position:Int = 0;
  public var state:CoState<TIn, TOut> = Ready;

  public function new(actions:Array<CoAction<TIn, TOut>>, labels:Map<String, Int>, vars:CoVariables) {
    this.actions = actions;
    this.labels = labels;
    this.vars = vars;
  }

  function checkEnd():Bool {
    if (position < 0 || position >= actions.length) {
      terminate();
      return true;
    }
    return false;
  }

  public function tick():Void {
    if (state != Ready)
      return;
    if (checkEnd())
      return;
    while (state.match(Ready) && position >= 0 && position < actions.length) {
      position = (switch (actions[position]) {
        case Sync(f, next):
          f(this);
          next;
        case Suspend(f, next):
          if (f(this))
            suspend();
          next;
        case If(cond, nextIf, nextElse):
          cond(this) ? nextIf : nextElse;
        case Accept(f, next):
          state = Accepting(f);
          next;
        case Yield(f, next):
          state = Yielding(f);
          next;
      });
    }
    if (state.match(Ready | Suspended))
      checkEnd();
  }

  public function suspend():Void {
    state = Suspended;
  }

  public function wakeup():Void {
    if (state != Ready && state != Suspended)
      throw "invalid state - can only wakeup Co in Ready or Suspended state";
    state = Ready;
    tick();
  }

  public function terminate():Void {
    state = Terminated;
  }

  public function give(value:TIn):Void {
    tick();
    switch (state) {
      case Accepting(f):
        f(this, value);
        state = Suspended;
        wakeup();
      case _:
        throw "invalid state - can only give to Co in Accepting state";
    }
  }

  public function take():TOut {
    tick();
    switch (state) {
      case Yielding(f):
        var ret = f(this);
        state = Suspended;
        wakeup();
        return ret;
      case _:
        throw 'invalid state - can only take from Co in Yielding state (is $state)';
        //throw "invalid state - can only take from Co in Yielding state";
    }
  }

  public function goto(label:String):Void {
    if (state == Terminated)
      throw "invalid state - Co is terminated";
    if (!labels.exists(label))
      throw "no such label";
    position = labels[label];
    state = Suspended;
    wakeup();
  }
}

enum CoState<TIn, TOut> {
  Ready;
  Suspended;
  Terminated;

  Accepting(_:(self:Co<TIn, TOut>, value:TIn) -> Void);
  Yielding(_:(self:Co<TIn, TOut>) -> TOut);
}
