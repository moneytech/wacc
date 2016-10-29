module WACC.Semantics.Semantics where

import           Data.Foldable
import           Data.Maybe
import           Control.Monad
import           Control.Monad.State
import           Control.Monad.Except
import           WACC.Semantics.Types
import           WACC.Semantics.Primitives
import           WACC.Semantics.Typing
import           WACC.Parser.Types

genCodePaths :: Statement -> SemanticChecker [[Statement]]
genCodePaths stmts
  = genCodePath stmts [[]]
  where
    genCodePath :: Statement -> [[Statement]] -> SemanticChecker [[Statement]]
    genCodePath (Block stmts) cps
      = foldrM (\(IdentifiedStatement s _) c -> genCodePath s c) cps stmts
    -- TODO: further optimizations and checks can be made for Conds and Loops
    -- by minimizing constant expressions (e.g. we can check if an `if` branch
    -- will ever be entered)
    genCodePath (Cond _ trueBranch falseBranch) cps
      = liftM2 (++) (genCodePath trueBranch cps) (genCodePath falseBranch cps)
    genCodePath (Loop _ body) cps
      = liftM2 (++) (genCodePath body cps) (return cps)
    genCodePath stmt cps
      = mapM (return . ((:) stmt)) cps


checkCodePathsReturn :: Definition -> SemanticChecker ()
checkCodePathsReturn ((ident, _), stmts) = do
  codePaths <- genCodePaths stmts
  unless (all (any isReturnOrExit) codePaths)
    $ invalid SemanticError "not all code paths return a value"


checkUnreachableCode :: Definition -> SemanticChecker ()
checkUnreachableCode ((ident, _), stmts) = do
  codePaths <- genCodePaths stmts
  when ((all (not . isReturnOrExit . last) codePaths)
        || (all ((> 1) . length . filter isReturnOrExit) codePaths))
    $ invalid SemanticError "unreachable code after return statement"


checkMainDoesNotReturn :: Definition -> SemanticChecker ()
checkMainDoesNotReturn (_, stmts) = do
  codePaths <- genCodePaths stmts
  unless (not (any (any isReturn) codePaths))
    $ invalid SemanticError "cannot return a value from the global scope"


checkDef :: Definition -> SemanticChecker ()
checkDef ((ident, (TFun rT paramT)), stmt) = do
  increaseScope
  mapM_ storeDecl paramT
  storeDecl ("%RETURN%", rT)
  checkStmt stmt
  decreaseScope


checkLhs :: Expr -> SemanticChecker ()
checkLhs (Ident _)
  = valid
checkLhs (ArrElem _ exprs)
  = mapM_ checkExpr exprs
checkLhs (PairElem _ _)
  = valid
checkLhs _
  = invalid SyntaxError "type error"


checkExpr :: Expr -> SemanticChecker ()
checkExpr (Lit lit)
  = valid
checkExpr (Ident ident)
  = identExists ident
checkExpr (ArrElem ident [])
  = invalid SemanticError "invalid array index"
checkExpr (ArrElem ident idx) = do
  mapM_ checkExpr idx
  types <- mapM getType idx
  mapM_ (equalTypes "array index must be an integer" TInt) types
checkExpr (PairElem pairElem ident) = do
  tp <- identLookup ident
  equalTypes "type error: pairElem requires a Pair" tp (TPair TArb TArb)
checkExpr (UnApp unop expr) = do
  checkExpr expr
  a <- getType expr
  checkUnopArgs unop a
checkExpr (BinApp binop e1 e2) = do
  checkExpr e1
  checkExpr e2
  a1 <- getType e1
  a2 <- getType e2
  checkBinopArgs binop a1 a2
checkExpr (FunCall ident args) = do
  mapM_ checkExpr args
  t <- identLookup ident
  case t of
    (TFun _ params) -> checkArgs params args
    _               -> invalid SemanticError "invalid argument"
  where
    checkArgs :: [Declaration] -> [Expr] -> SemanticChecker ()
    checkArgs params args = do
      types <- mapM getType args
      case (map snd params) == types of
        True  -> valid
        False -> invalid SemanticError "invalid argument"
checkExpr (NewPair e1 e2)
  = checkExpr e1 >> checkExpr e2


checkStmt :: Statement -> SemanticChecker ()
checkStmt (Noop)
  = valid
checkStmt (Block idStmts)
  = scoped $ mapM_ checkStmt idStmts
checkStmt (VarDef decl expr) = do
  checkExpr expr
  t <- getType expr
  equalTypes ("type Mismatch " ++ show(snd decl) ++ " vs " ++ show(t)) (snd decl) t
  storeDecl decl
checkStmt (Ctrl Break)
  = valid
checkStmt (Ctrl Continue)
  = valid
checkStmt (Ctrl (Return e)) = do
  checkExpr e
  rT <- identLookup "%RETURN%"
  t <- getType e
  equalTypes "return type must be the same as the function type" rT t
checkStmt (Cond e s1 s2)
  = checkExpr e >> scoped (checkStmt s1) >> scoped (checkStmt s2)
checkStmt (Loop cond stmt) = do
  checkExpr cond
  t <- getType cond
  equalTypes "type mismatch" TBool t
  scoped $ checkStmt stmt
checkStmt (Builtin func ex) = do
  checkExpr ex
  checkBuiltinArg func ex
  where
    checkBuiltinArg Read (Ident _) = valid
    checkBuiltinArg Read (ArrElem _ _) = valid
    checkBuiltinArg Read (PairElem _ _) = valid
    checkBuiltinArg Read e = invalid SemanticError "invalid argument"
    checkBuiltinArg Free e = do
      t <- getType e
      case t of
        (TPair _ _) -> valid
        (TArray _)  -> valid
        _           -> invalid SemanticError "invalid argument"
    checkBuiltinArg Exit e = do
      t <- getType e
      equalTypes "invalid argument" TInt t
    checkBuiltinArg Print e = valid
    checkBuiltinArg PrintLn e = valid
checkStmt (ExpStmt e)
  = checkExpr e
checkStmt (IdentifiedStatement stmt i)
  = checkStmt stmt `catchError` rethrowWithLocation i


storeDecl :: Declaration -> SemanticChecker ()
storeDecl (ident, t)
  = addSymbol (Symbol ident t)


storeFuncs :: [Definition] -> SemanticChecker ()
storeFuncs defs
  = mapM_ storeDecl $ map fst defs


semanticCheck :: Program -> SemanticChecker ()
semanticCheck (mainF:funcs) = do
  mapM_ checkCodePathsReturn funcs
  mapM_ checkUnreachableCode funcs
  checkMainDoesNotReturn mainF
  storeFuncs funcs
  mapM_ checkDef (mainF:funcs)
