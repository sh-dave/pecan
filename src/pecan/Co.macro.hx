package pecan;

import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.ExprTools;
import haxe.macro.Type;
import haxe.macro.TypedExprTools;

using haxe.macro.MacroStringTools;

typedef LocalVar = {
  /**
    Name of the original variable.
  **/
  name:String,

  type:ComplexType,

  /**
    Position where the original variable was declared.
  **/
  declaredPos:Position,

  /**
    Name of the renamed variable, field on the variables class.
  **/
  renamed:String,

  /**
    `false` if the variable cannot be written to in user code, e.g. when it is
    actually a loop variable.
  **/
  readOnly:Bool,

  argOptional:Bool
};

typedef LocalScope = Map<String, Array<LocalVar>>;

typedef ProcessContext = {
  /**
    The AST representation, changed with each processing stage.
  **/
  block:Expr,

  labels:Map<String, Int>,

  pos:Position,

  /**
    Counter for declaring coroutine-local variables.
  **/
  localCounter:Int,

  topScope:LocalScope,
  scopes:Array<LocalScope>,

  /**
    Type path of the class holding the coroutine-local variables.
  **/
  varsTypePath:TypePath,

  varsComplexType:ComplexType,

  /**
    All locals declared for the coroutine.
  **/
  locals:Array<LocalVar>,

  /**
    Argument variables passed during `run`. A subset of locals.
  **/
  arguments:Array<LocalVar>,

  typeInput:ComplexType,
  typeOutput:ComplexType
};

class Co {
  static var debug = false;
  static var typeCounter = 0;
  static var ctx:ProcessContext;

  static var printer = new haxe.macro.Printer();

  static var tin:ComplexType;
  static var tout:ComplexType;

  /**
    Initialises the type path and complex type for the class that will hold
    the coroutine-local variables.
  **/
  static function initVariableClass():Void {
    ctx.varsTypePath = {name: 'CoVariables$typeCounter', pack: ["pecan", "instances"]};
    ctx.varsComplexType = ComplexType.TPath(ctx.varsTypePath);
  }

  static function declareLocal(varsExpr:Expr, name:String, type:ComplexType, expr:Expr, readOnly:Bool):LocalVar {
    if (type == null && expr == null)
      Context.error('invalid variable declaration for $name - must have either a type hint or an expression', varsExpr.pos);
    if (type == null) {
      function mapType(e:Expr):Expr {
        return (switch (e.expr) {
          case ECall({expr: EConst(CIdent("accept"))}, []):
            macro (null : $tin);
          case EConst(CIdent(ident)):
            var res = findLocal(e, ident, false);
            if (res != null) {
              var tvar = res.type;
              macro {_v: (null : $tvar)}._v;
            } else e;
          case _:
            ExprTools.map(e, mapType);
        });
      }
      var mapped = mapType(expr);
      type = try Context.toComplexType(Context.typeof(mapped)) catch (e:Dynamic) {
        // if (debug) trace("cannot type", printer.printExpr(mapped), e);
        Context.error('cannot infer type for $name - provide a type hint', expr.pos);
      };
      // if (debug) trace("typed", printer.printExpr(mapped), type);
    }
    if (name != null && !ctx.topScope.exists(name))
      ctx.topScope[name] = [];
    var localVar = {
      name: name,
      type: type,
      declaredPos: varsExpr.pos,
      renamed: '_coLocal${ctx.localCounter++}',
      readOnly: readOnly,
      argOptional: false
    }
    if (name != null)
      ctx.topScope[name].push(localVar);
    ctx.locals.push(localVar);
    // trace('${localVar.renamed} <- $name', ctx.scopes);
    return localVar;
  }

  static function findLocal(expr:Expr, name:String, write:Bool):Null<LocalVar> {
    for (i in 0...ctx.scopes.length) {
      var ri = ctx.scopes.length - i - 1;
      if (ctx.scopes[ri].exists(name)) {
        var scope = ctx.scopes[ri][name];
        // trace(name, scope);
        if (scope.length > 0) {
          var localVar = scope[scope.length - 1];
          if (localVar.readOnly && write)
            Context.error('cannot write to read-only variable $name', expr.pos);
          return localVar;
        }
      }
    }
    return null;
  }

  static function accessLocal(expr:Expr, name:String, write:Bool):Null<Expr> {
    var localVar = findLocal(expr, name, write);
    if (localVar == null)
      return null;
    return accessLocal2(localVar, expr.pos);
  }

  static function withPos(expr:Expr, ?pos:Position):Expr {
    return {expr: expr.expr, pos: pos != null ? pos : expr.pos};
  }

  static function accessLocal2(localVar:LocalVar, ?pos:Position):Expr {
    var varsComplexType = ctx.varsComplexType;
    var renamed = localVar.renamed;
    return withPos(macro(cast self.vars : $varsComplexType).$renamed, pos);
  }

  /**
    Checks if the coroutine block consists of a function, parses the arguments
    into separate variables if so.
  **/
  static function processArguments():Void {
    switch (ctx.block.expr) {
      case EFunction(_, f):
        if (f.ret != null)
          Context.error("coroutine function should not have a return type hint", ctx.block.pos);
        if (f.params != null && f.params.length > 0)
          Context.error("coroutine function should not have type parameters", ctx.block.pos);
        var block = [];
        for (arg in f.args) {
          var argLocal = declareLocal(ctx.block, arg.name, arg.type, arg.value, false);
          ctx.arguments.push(argLocal);
          var argAccess = accessLocal2(argLocal, ctx.block.pos);
          if (arg.opt)
            argLocal.argOptional = true;
          if (arg.opt && arg.value != null) {
            block.push(macro {
              if ($argAccess == null)
                $argAccess = ${arg.value};
            });
          }
        }
        function stripReturn(e:Expr):Expr {
          return (switch (e.expr) {
            case EBlock([e]) | EReturn(e) | EMeta({name: ":implicitReturn"}, e):
              stripReturn(e);
            case _:
              e;
          });
        }
        block.push(stripReturn(f.expr));
        ctx.block = withPos(macro $b{block}, ctx.block.pos);
      case _:
    }
  }

  /**
    Renames variables to unique identifiers to match variable scopes.
  **/
  static function processVariables():Void {
    function scoped<T>(visit:() -> T):T {
      ctx.scopes.push(ctx.topScope = []);
      var ret = visit();
      ctx.scopes.pop();
      ctx.topScope = ctx.scopes[ctx.scopes.length - 1];
      return ret;
    }
    function walk(e:Expr):Expr {
      // if (debug) trace("walking", e);
      return {
        pos: e.pos,
        expr: (switch (e.expr) {
          // manage scopes
          case EBlock(sub):
            EBlock(scoped(() -> sub.map(walk)));
          case ESwitch(e, cases, edef):
            ESwitch(walk(e), [
              for (c in cases)
                {expr: c.expr != null ? walk(c.expr) : null, guard: c.guard != null ? walk(c.guard) : null, values: ExprArrayTools.map(c.values, walk)}
            ], edef == null || edef.expr == null ? edef : scoped(() -> walk(edef)));
          // change map comprehensions into loops
          case EArrayDecl([loop = {expr: EFor(it, {expr: EBinop(OpArrow, key, val)})}]):
            var exprs = [];
            var tmpVarAccess = accessLocal2(declareLocal(e, null, null, e, true), e.pos);
            exprs.push(macro $tmpVarAccess = new Map());
            exprs.push(walk({expr: EFor(it, macro $tmpVarAccess.set($e{key}, $e{val})), pos: loop.pos}));
            exprs.push(tmpVarAccess);
            EBlock(exprs);
          case EArrayDecl([loop = {expr: EWhile(it, {expr: EBinop(OpArrow, key, val)}, normalWhile)}]):
            var exprs = [];
            var tmpVarAccess = accessLocal2(declareLocal(e, null, null, e, true), e.pos);
            exprs.push(macro $tmpVarAccess = new Map());
            exprs.push(walk({expr: EWhile(it, macro $tmpVarAccess.set($e{key}, $e{val}), normalWhile), pos: loop.pos}));
            exprs.push(tmpVarAccess);
            EBlock(exprs);
          // change array comprehensions into loops
          case EArrayDecl([loop = {expr: EFor(it, body)}]):
            var exprs = [];
            var tmpVarAccess = accessLocal2(declareLocal(e, null, null, e, true), e.pos);
            exprs.push(macro $tmpVarAccess = []);
            exprs.push(walk({expr: EFor(it, macro $tmpVarAccess.push($e{body})), pos: loop.pos}));
            exprs.push(tmpVarAccess);
            EBlock(exprs);
          case EArrayDecl([loop = {expr: EWhile(it, body, normalWhile)}]):
            var exprs = [];
            var tmpVarAccess = accessLocal2(declareLocal(e, null, null, e, true), e.pos);
            exprs.push(macro $tmpVarAccess = []);
            exprs.push(walk({expr: EWhile(it, macro $tmpVarAccess.push($e{body}), normalWhile), pos: loop.pos}));
            exprs.push(tmpVarAccess);
            EBlock(exprs);
          // change key-value `for` loops to `while` loops
          case EFor({expr: EBinop(OpArrow, kv = {expr: EConst(CIdent(k))}, {expr: EBinop(OpIn, vv = {expr: EConst(CIdent(v))}, it)})}, body):
            var exprs = [];
            try {
              if (!Context.unify(Context.typeof(it), Context.resolveType(macro:KeyValueIterator<Dynamic>, Context.currentPos())))
                throw 0;
            } catch (e:Dynamic) {
              it = macro $it.keyValueIterator();
            }
            var iterVarAccess = accessLocal2(declareLocal(it, null, null, it, true), it.pos);
            var iterStructAccess = accessLocal2(declareLocal(it, null, null, macro $it.next(), true), it.pos);
            var keyVar = declareLocal(kv, k, null, macro $it.next().key, true);
            var valueVar = declareLocal(vv, v, null, macro $it.next().value, true);
            exprs.push(macro $iterVarAccess = $it);
            exprs.push(macro while ($iterVarAccess.hasNext()) {
              $iterStructAccess = $iterVarAccess.next();
              $e{accessLocal2(keyVar, kv.pos)} = $iterStructAccess.key;
              $e{accessLocal2(valueVar, vv.pos)} = $iterStructAccess.value;
              $e{walk(body)};
            });
            return macro $b{exprs};
          // change `for` loops to `while` loops
          case EFor({expr: EBinop(OpIn, ev = {expr: EConst(CIdent(v))}, it)}, body):
            var exprs = [];
            try {
              if (!Context.unify(Context.typeof(it), Context.resolveType(macro:Iterator<Dynamic>, Context.currentPos())))
                throw 0;
            } catch (e:Dynamic) {
              it = macro $it.iterator();
            }
            var iterVarAccess = accessLocal2(declareLocal(it, null, null, it, true), it.pos);
            var loopVar = declareLocal(ev, v, null, macro $it.next(), true);
            exprs.push(macro $iterVarAccess = $it);
            exprs.push(macro while ($iterVarAccess.hasNext()) {
              $e{accessLocal2(loopVar, ev.pos)} = $iterVarAccess.next();
              $e{walk(body)};
            });
            return macro $b{exprs};
          // rename variables
          case EVars(vars):
            var exprs = [];
            for (v in vars) {
              if (v.isFinal)
                Context.error("final variables are not supported in coroutines", e.pos);
              var localVar = declareLocal(e, v.name, v.type, v.expr, false);
              if (v.expr != null) {
                var access = accessLocal2(localVar);
                exprs.push(macro $access = $e{walk(v.expr)});
              }
            }
            return macro $b{exprs};
          // resolve identifiers to renamed variables
          case EBinop(binop = OpAssign | OpAssignOp(_), ev = {expr: EConst(CIdent(ident))}, rhs):
            var res = accessLocal(ev, ident, true);
            return {expr: EBinop(binop, res != null ? res : ev, walk(rhs)), pos: e.pos};
          case EConst(CIdent(ident)):
            // trace('ident: $ident -> ${lookup(ident)}');
            var res = accessLocal(e, ident, false);
            return res != null ? res : e;
          // handle format strings
          case EConst(CString(s)):
            if (MacroStringTools.isFormatExpr(e))
              return walk(s.formatString(e.pos));
            return e;
          case _:
            return ExprTools.map(e, walk);
        })
      };
    }
    ctx.block = walk(ctx.block);
    if (debug) {
      Sys.println(new haxe.macro.Printer().printExpr(ctx.block));
    }
  }

  /**
    Defines the class for coroutine-local variables.
  **/
  static function finaliseVariableClass():Void {
    var varsTypeName = ctx.varsTypePath.name;
    var varsType = macro class $varsTypeName extends pecan.CoVariables {
      public function new() {}
    };
    varsType.pack = ctx.varsTypePath.pack;
    for (localVar in ctx.locals) {
      varsType.fields.push({
        access: [APublic],
        name: localVar.renamed,
        kind: FVar(localVar.type, null),
        pos: localVar.declaredPos
      });
    }
    // Sys.println(new haxe.macro.Printer().printTypeDefinition(varsType));
    Context.defineType(varsType);
  }

  /**
    Converts a code block to a valid `Co` construction.
    Performs CFA to translate nested blocks into a single array of `CoAction`s.
  **/
  static function convert():Void {
    var cfa:Array<CFA> = [];
    function push(kind:CFAKind, expr:Null<Expr>, next:Array<CFA>):CFA {
      var ret:CFA = {
        kind: kind,
        expr: expr,
        next: next,
        prev: [],
        idx: -1
      };
      for (n in next)
        if (n != null)
          n.prev.push(ret);
      cfa.push(ret);
      return ret;
    }
    var loops:Array<{cond:CFA, next:CFA}> = [];
    var walk:(e:Expr, next:CFA) -> CFA = null;
    function walkExpr(e:Expr, next:CFA):{e:Expr, next:CFA} {
      function sub(e:Expr):Expr {
        var ret = walkExpr(e, next);
        next = ret.next;
        return ret.e;
      }
      return (switch (e.expr) {
        // special calls
        case ECall({expr: EConst(CIdent("accept"))}, []):
          // if (!allowAccept)
          //  Context.error("invalid location for accept() call", e.pos);
          var tmpVarAccess = accessLocal2(declareLocal(e, null, tin, null, true), e.pos);
          var accept = push(Accept, macro $tmpVarAccess = _pecan_value, [next]);
          {e: macro $tmpVarAccess, next: accept};
        // expressions which should have been filtered out by now
        case EVars(_) | EFor(_, _) | EWhile(_, _, _) | EReturn(_) | EBreak | EContinue:
          Context.error("unexpected", e.pos);
        // unmapped expressions
        case EConst(_) | EFunction(_, _) | ESwitch(_, _, _) | EUntyped(_) | EDisplay(_, _) | EDisplayNew(_):
          {e: e, next: next};
        // normal expressions
        case EArray(sub(_) => e1, sub(_) => e2):
          {e: {expr: EArray(e1, e2), pos: e.pos}, next: next};
        // case EBinop(OpBoolAnd, e1, e2):
        case EBinop(op, sub(_) => e1, sub(_) => e2): // TODO: order of evaluation? short circuiting?
          {e: {expr: EBinop(op, e1, e2), pos: e.pos}, next: next};
        case EField(sub(_) => e1, field):
          {e: {expr: EField(e1, field), pos: e.pos}, next: next};
        case EParenthesis(sub(_) => e1):
          {e: {expr: EParenthesis(e1), pos: e.pos}, next: next};
        case EObjectDecl(fields): // TODO: reverse fields
          var fields = fields.map(f -> {
            expr: sub(f.expr),
            field: f.field,
            quotes: f.quotes
          });
          {e: {expr: EObjectDecl(fields), pos: e.pos}, next: next};
        case EArrayDecl(_.map(sub) => values):
          {e: {expr: EArrayDecl(values), pos: e.pos}, next: next};
        case ECall(e1, params):
          var params = params.map(sub);
          var e1 = sub(e1);
          {e: {expr: ECall(e1, params), pos: e.pos}, next: next};
        case ENew(t, params):
          var params = params.map(sub);
          {e: {expr: ENew(t, params), pos: e.pos}, next: next};
        case EUnop(op, postFix, sub(_) => e1):
          {e: {expr: EUnop(op, postFix, e1), pos: e.pos}, next: next};
        case EBlock(es):
          if (es.length == 0)
            {e: {expr: EBlock([]), pos: e.pos}, next: next};
          else {
            var last = sub(es[es.length - 1]);
            for (ri in 1...es.length)
              next = walk(es[es.length - ri - 1], next);
            {e: last, next: next};
          }
        case EIf(sub(_) => econd, sub(_) => eif, sub(_) => eelse):
          // TODO: branch dependencies are always executed
          {e: {expr: EIf(econd, eif, eelse), pos: e.pos}, next: next};
        case EThrow(sub(_) => e1):
          {e: {expr: EThrow(e1), pos: e.pos}, next: next};
        case ECast(sub(_) => e1, t):
          {e: {expr: ECast(e1, t), pos: e.pos}, next: next};
        case ETernary(sub(_) => e1, sub(_) => e2, sub(_) => e3):
          {e: {expr: ETernary(e1, e2, e3), pos: e.pos}, next: next};
        case ECheckType(sub(_) => e1, t):
          {e: {expr: ECheckType(e1, t), pos: e.pos}, next: next};
        case EMeta(s, sub(_) => e1):
          {e: {expr: EMeta(s, e1), pos: e.pos}, next: next};
        case _:
          {e: e, next: next};
          // Context.error('complex expr ${e.expr}', e.pos);
      });
    }
    walk = function (e:Expr, next:CFA):CFA {
      if (e == null)
        return next;
      return (switch (e.expr) {
        // special calls
        case ECall({expr: EConst(CIdent("terminate"))}, []):
          push(Sync, macro self.terminate(), []);
        case ECall({expr: EConst(CIdent("suspend"))}, []):
          push(Suspend, macro return true, [next]);
        case ECall({expr: EConst(CIdent("suspend"))}, [f]):
          push(Suspend, macro {
            $f(self, self.wakeup);
            return true;
          }, [next]);
        case ECall({expr: EConst(CIdent("yield"))}, [expr]):
          var yield = push(Yield, null, [next]);
          var expr = walkExpr(expr, yield);
          yield.expr = macro return $e{expr.e};
          expr.next;
        case ECall(f, args) if (checkSuspending(f)):
          var call = push(Suspend, null, [next]);
          var next = call;
          var args = [
            for (ri in 0...args.length) {
              var ret = walkExpr(args[args.length - ri - 1], next);
              next = ret.next;
              ret.e;
            }
          ];
          args.push(macro self);
          args.push(macro self.wakeup);
          call.expr = macro return $f($a{args});
          next;
        case ECall({expr: EConst(CIdent("label"))}, [{expr: EConst(CString(label))}]):
          push(Label(label), null, [next]);
        // optimised variants
        // TODO: while (true) optimisation breaks labels
        //case EWhile({expr: EConst(CIdent("true"))}, body, _):
        //  var cfaBody = walk(body, null);
        //  cfaBody.next = [cfaBody, cfaBody];
        //  cfaBody.prev.push(cfaBody);
        //  cfaBody;
        case EIf({expr: EConst(CIdent("true"))}, eif, _):
          walk(eif, next);
        case EIf({expr: EConst(CIdent("false"))}, _, eelse):
          walk(eelse, next);
        // normal blocks
        case EBlock(es):
          var next = next;
          for (ri in 0...es.length)
            next = walk(es[es.length - ri - 1], next);
          next;
        case EIf(cond, eif, eelse):
          var cfaIf = walk(eif, next);
          var cfaElse = eelse == null ? next : walk(eelse, next);
          var cfaCond = push(If, null, [cfaIf, cfaElse]);
          var cond = walkExpr(cond, cfaCond);
          cfaCond.expr = macro return $e{cond.e};
          cond.next;
        case EWhile(cond, body, normalWhile):
          var cfaCond = push(If, null, [next]);
          var cond = walkExpr(cond, cfaCond);
          loops.push({cond: cfaCond, next: next});
          var cfaBody = walk(body, cond.next);
          loops.pop();
          cfaCond.expr = macro return $e{cond.e};
          cfaCond.next.unshift(cfaBody);
          cfaBody.prev.push(cfaCond);
          normalWhile ? cond.next : cfaBody;
        case EBreak if (loops.length > 0):
          loops[loops.length - 1].next;
        case EContinue if (loops.length > 0):
          loops[loops.length - 1].cond;
        case EBreak | EContinue:
          Context.error("break and continue are only allowed in loops", e.pos);
        case _:
          var cfaSync = push(Sync, null, [next]);
          var res = walkExpr(e, cfaSync);
          cfaSync.expr = res.e;
          res.next;
      });
    }
    function mergeBlock(a:Expr, b:Expr):Expr {
      return (switch [a, b] {
        case [{expr: EBlock(as)}, {expr: EBlock(bs), pos: pos}]:
          {expr: EBlock(as.concat(bs)), pos: pos};
        case [_, {expr: EBlock(bs), pos: pos}]:
          {expr: EBlock([a].concat(bs)), pos: pos};
        case [{expr: EBlock(as)}, {expr: _, pos: pos}]:
          {expr: EBlock(as.concat([b])), pos: pos};
        case [_, {expr: _, pos: pos}]:
          {expr: EBlock([a, b]), pos: pos};
      });
    }
    function optimise(c:CFA):CFA {
      if (c == null || c.idx == -2)
        return c;
      c.idx = -2;
      return (switch (c) {
        case {kind: Sync, next: [null]}:
          c.next = c.next.map(optimise);
          c;
        case {kind: Sync, next: [next = {prev: [_]}]}:
          next.expr = mergeBlock(c.expr, next.expr);
          next.prev = c.prev;
          for (p in c.prev)
            p.next = p.next.map(n -> n == c ? next : n);
          optimise(next);
        case _:
          c.next = c.next.map(optimise);
          c;
      });
    }
    var actions:Array<Expr> = [];
    var labels:Map<String, Int> = [];
    function finalise(c:CFA):Int {
      if (c == null)
        return -1;
      if (c.idx >= 0)
        return c.idx;
      c.idx = actions.length;
      function idx(n:Int):Int {
        return n >= c.next.length ? -1 : finalise(c.next[n]);
      }
      switch (c.kind) {
        case Label(label):
          labels[label] = c.idx = finalise(c.next[0]);
        case _:
          actions.push(null);
      }
      actions[c.idx] = (switch (c.kind) {
        case Sync:
          macro pecan.CoAction.Sync(function(self:pecan.Co<$tin, $tout>):Void {
            $e{c.expr};
          }, $v{idx(0)});
        case Suspend:
          macro pecan.CoAction.Suspend(function(self:pecan.Co<$tin, $tout>):Bool {
            $e{c.expr};
          }, $v{idx(0)});
        case If:
          macro pecan.CoAction.If(function(self:pecan.Co<$tin, $tout>):Bool {
            $e{c.expr};
          }, $v{idx(0)}, $v{idx(1)});
        case Accept:
          macro pecan.CoAction.Accept(function(self:pecan.Co<$tin, $tout>, _pecan_value:$tin):Void {
            $e{c.expr};
          }, $v{idx(0)});
        case Yield:
          macro pecan.CoAction.Yield(function(self:pecan.Co<$tin, $tout>):$tout {
            $e{c.expr};
          }, $v{idx(0)});
        case Label(_):
          return c.idx;
      });
      return c.idx;
    }
    finalise(optimise(walk(ctx.block, null)));
    ctx.block = macro $a{actions};
    ctx.labels = labels;
    if (debug) {
      Sys.println(new haxe.macro.Printer().printExpr(ctx.block));
    }
  }

  /**
    Checks whether the given expressions resolves to a function marked with
    the @:pecan.suspend metadata.
  **/
  static function checkSuspending(f:Expr):Bool {
    var typed = try Context.typeExpr(macro function(self:pecan.Co<$tin, $tout>) {
      $f;
    }) catch (e:Dynamic) null;
    if (typed == null)
      return false;
    switch (typed.expr) {
      case TFunction({expr: {expr: TBlock([{expr: TField(_, FStatic(_, _.get().meta.has(":pecan.suspend") => true))}])}}):
        return true;
      case _:
        return false;
    }
  }

  /**
    Builds and returns a factory subtype.
  **/
  static function buildFactory():Expr {
    var varsTypePath = ctx.varsTypePath;
    var factoryTypePath = {name: 'CoFactory$typeCounter', pack: ["pecan", "instances"]};
    var factoryTypeName = factoryTypePath.name;
    var labelsExpr = [ for (label => idx in ctx.labels) macro $v{label} => $v{idx} ];
    var factoryType = macro class $factoryTypeName extends pecan.CoFactory<$tin, $tout> {
      public function new(actions:Array<pecan.CoAction<$tin, $tout>>) {
        super(actions, $a{labelsExpr}, args -> {
          var ret = new $varsTypePath();
          $b{
            [
              for (i in 0...ctx.arguments.length)
                macro $p{["ret", ctx.arguments[i].renamed]} = args[$v{i}]
            ]
          };
          ret;
        });
      }
    };
    factoryType.pack = factoryTypePath.pack;
    factoryType.fields.push({
      access: [APublic],
      kind: FFun({
        args: [
          for (i in 0...ctx.arguments.length)
            {
              name: 'arg$i',
              type: ctx.arguments[i].type,
              opt: ctx.arguments[i].argOptional
            }
        ],
        expr: macro return $e{
          {
            expr: ECall({expr: EConst(CIdent("runBase")), pos: ctx.pos}, [
              {
                expr: EArrayDecl([
                  for (i in 0...ctx.arguments.length)
                    {
                      expr: EConst(CIdent('arg$i')),
                      pos: ctx.pos
                    }
                ]),
                pos: ctx.pos
              }
            ]),
            pos: ctx.pos
          }
        },
        ret: macro:pecan.Co<$tin, $tout>
      }),
      name: "run",
      pos: ctx.pos
    });
    // Sys.println(new haxe.macro.Printer().printTypeDefinition(factoryType));
    Context.defineType(factoryType);
    // actions are passed by argument to allow for closure variable capture
    return macro new $factoryTypePath(${ctx.block});
  }

  /**
    Parses an expr like `(_ : Type)` to a ComplexType.
  **/
  static function parseIOType(e:Expr):ComplexType {
    return (switch (e) {
      case {expr: ECheckType(_, t) | EParenthesis({expr: ECheckType(_, t)})}: t;
      case macro null: macro:Void;
      case _: throw "invalid i/o type";
    });
  }

  public static function co(block:Expr, ?tinE:Expr, ?toutE:Expr):Expr {
    ctx = {
      block: block,
      labels: null,
      pos: block.pos,
      localCounter: 0,
      varsTypePath: null,
      varsComplexType: null,
      locals: [],
      arguments: [],
      topScope: [],
      scopes: null,
      typeInput: parseIOType(tinE),
      typeOutput: parseIOType(toutE)
    };
    ctx.scopes = [ctx.topScope];
    tin = ctx.typeInput;
    tout = ctx.typeOutput;

    initVariableClass();
    processArguments();
    processVariables();
    convert();
    finaliseVariableClass();
    var factory = buildFactory();

    typeCounter++;
    ctx = null;
    tin = null;
    tout = null;
    return factory;
  }

  public static function coDebug(block:Expr, ?tin:Expr, ?tout:Expr):Expr {
    debug = true;
    var ret = co(block, tin, tout);
    debug = false;
    return ret;
  }
}

typedef CFA = {
  kind:CFAKind,
  expr:Null<Expr>,
  next:Array<CFA>,
  prev:Array<CFA>,
  idx:Int
};

enum CFAKind {
  Sync;
  Suspend;
  If;
  Accept;
  Yield;
  Label(label:String);
}
