module WACC.Parser.Parser where

import           Control.Monad
import           Data.Int
import           Data.List
import           Data.Maybe
import qualified Data.Map as Map
import           Data.Map (Map)
import           Text.ParserCombinators.Parsec hiding (label)
import           Text.ParserCombinators.Parsec.Error
import           Text.Parsec.Expr
import           Text.Parsec.Pos

import           WACC.Parser.Types
import           WACC.Parser.Primitives
import           WACC.Semantics.Typing

initialParserState :: LocationData
initialParserState
  = LocationData Map.empty 0


getNextIdentifier :: GenParser Char LocationData StatementId
getNextIdentifier = do
  LocationData locs c <- getState
  setState (LocationData locs (c+1))
  return c

savePosition :: StatementId -> GenParser Char LocationData ()
savePosition i = do
  LocationData locs c <- getState
  pos <- getPosition
  let newLocs = Map.insert i (Location (sourceLine pos) (sourceColumn pos)) locs
  setState (LocationData newLocs c)

-- Parsing
escape :: GenParser Char LocationData Char
escape = do
    d <- char '\\'
    c <- oneOf escapeCodes
    let i = fromJust $ elemIndex c escapeCodes
    return (escapedCharacters !! i)
    where
      escapeCodes = "\\\"\'0nrvtbf"

nonEscape :: GenParser Char LocationData Char
nonEscape
  = noneOf escapedCharacters

character :: GenParser Char LocationData Char
character
  = nonEscape <|> escape

integer :: GenParser Char LocationData Integer
integer = do
  s <- option id sign
  n <- many1 digit
  return . s . read $ n
  where
    sign = opMap "+" id <|> opMap "-" negate

isKeyword :: String -> Bool
isKeyword k
  = any (elem k) [keywords, map fst builtins, map fst primTypes]

identifier :: GenParser Char LocationData Identifier
identifier = do
  whitespace
  c <- letter <|> char '_'
  cs <- many identifierChar
  let ident = c : cs
  if isKeyword ident then
    fail "identifier is a keyword"
  else
    return ident

pair :: GenParser Char LocationData a -> GenParser Char LocationData (a, a)
pair p = try $ do
  wschar '('
  p1 <- p
  wschar ','
  p2 <- p
  wschar ')'
  return (p1, p2)

literal :: GenParser Char LocationData Literal
literal
  = charLit <|> intLit <|> boolLit <|> strLit <|> arrLit <|> nullLit
  where
    charLit
      = CHAR <$> try (between (char '\'') (char '\'') character)

    intLit
      = INT <$> try integer

    boolLit
      = BOOL <$> try (reserved "true" True <|> reserved "false" False)

    strLit
      = STR <$> try (quoted (many character))

    arrLit
      = ARRAY <$> try (bracketed (expr `sepBy` comma))

    nullLit
      = try (keyword "null" >> return NULL)


decltype :: GenParser Char LocationData Type
decltype
  = structType <|> arrType <|> pairType <|> primType
  where
    primType
      = choice (map (uncurry reserved) primTypes)

    arrType = try $ do
      t <- pairType <|> primType
      qualifiers <- many1 (arrQualifier <|> ptrQualifier)
      return $ foldr1 (flip (.)) qualifiers t

    arrQualifier
      = reserved "[]" TArray

    ptrQualifier
      = reserved "*" TPtr

    pairType = try $ do
      keyword "pair"
      (t1, t2) <- option (TArb, TArb) (pair decltype)
      return $ TPair t1 t2

    structType
      = try $ (TPtr . TStruct) <$> (keyword "struct" *> identifier)

varDecl :: GenParser Char LocationData Declaration
varDecl = try $ do
  t <- wssurrounded decltype
  ident <- wssurrounded identifier
  return (ident, t)

funDecl :: GenParser Char LocationData Declaration
funDecl = try $ do
  retT <- wssurrounded decltype
  ident <- wssurrounded identifier
  args <- parens (varDecl `sepBy` comma)
  return  (ident, TFun retT args)

expr :: GenParser Char LocationData Expr
expr
  = buildExpressionParser operations (wssurrounded term)
  where
    term
      = parens expr <|> funCall <|> newPair <|> newStruct <|> val
        <|> arrElement <|> pairElement <|> ident

val :: GenParser Char LocationData Expr
val
  = try $ Lit <$> literal

ident :: GenParser Char LocationData Expr
ident = try $ Ident <$> identifier

arrElement :: GenParser Char LocationData Expr
arrElement
  = try $ ArrElem <$> identifier <*> many1 (bracketed expr)

pairElement :: GenParser Char LocationData Expr
pairElement
  = try $ PairElem <$> (reserved "fst" Fst <|> reserved "snd" Snd)
                   <*> identifier

funCall :: GenParser Char LocationData Expr
funCall = try $ do
  keyword "call"
  FunCall <$> identifier <*> (whitespace *> parens (expr `sepBy` comma))

newPair :: GenParser Char LocationData Expr
newPair = try $ do
  keyword "newpair"
  (e1, e2) <- pair expr
  return $ NewPair e1 e2

newStruct :: GenParser Char LocationData Expr
newStruct = try $ do
  keyword "news"
  NewStruct <$> identifier

stmt :: GenParser Char LocationData Statement
stmt
  = inlineAsm <|> block <|> varDef <|> control <|> cond
    <|> extern <|> loop <|> builtin <|> noop <|> expStmt

idStmt :: GenParser Char LocationData Statement
idStmt = do
  i <- getNextIdentifier
  savePosition i
  s <- stmt
  return $ IdentifiedStatement s i

stmtSeq :: GenParser Char LocationData Statement
stmtSeq
  = try $ Block <$> idStmt `sepBy` semicolon

noop :: GenParser Char LocationData Statement
noop
  = try $ keyword "skip" *> return Noop

extern :: GenParser Char LocationData Statement
extern = try $ do
  keyword "extern"
  i <- identifier
  return $ ExternDecl i

inlineAsm :: GenParser Char LocationData Statement
inlineAsm = try $ do
  keyword "begin inline"
  ss <- manyTill anyChar (try $ keyword "end")
  return $ InlineAssembly [ss]

block :: GenParser Char LocationData Statement
block = try $ do
  keyword "begin"
  stmts <- idStmt `sepBy` semicolon
  keyword "end"
  return $ Block stmts

varDef :: GenParser Char LocationData Statement
varDef
  = try $ VarDef <$> varDecl <*> (whitespace *> char '=' *> expr)

control :: GenParser Char LocationData Statement
control
  = Ctrl <$> (ret <|> break <|> cont)
  where
    ret
      = reserved "return" Return <*> expr

    break
      = reserved "break" Break

    cont
      = reserved "continue" Continue

cond :: GenParser Char LocationData Statement
cond = try $ do
  keyword "if"
  e <- expr
  keyword "then"
  trueBranch <- stmtSeq
  falseBranch <- option Noop (keyword "else" *> stmtSeq)
  keyword "fi"
  return $ Cond e trueBranch falseBranch

loop :: GenParser Char LocationData Statement
loop
  = whileLoop <|> forLoop
  where
    forLoop = try $ do
      keyword "for"
      i <- getNextIdentifier
      savePosition i
      init <- varDef
      semicolon
      cond <- expr
      semicolon
      step <- expStmt
      keyword "do"
      body <- stmtSeq
      keyword "done"
      return $ Block [IdentifiedStatement init i,
        IdentifiedStatement (Loop cond (Block [IdentifiedStatement body i,
          IdentifiedStatement step i])) i]

    whileLoop = try $ do
      keyword "while"
      e <- expr
      keyword "do"
      body <- stmtSeq
      keyword "done"
      return $ Loop e body

builtin :: GenParser Char LocationData Statement
builtin
  = Builtin <$> builtinFunc <*> expr
  where
    builtinFunc
      =  try $ choice (map (uncurry reserved) builtins)

expStmt :: GenParser Char LocationData Statement
expStmt
  = try $ ExpStmt <$> expr

definition :: GenParser Char LocationData Definition
definition
  = funDef <|> structDef <|> globalDef
  where
    funDef
      = try $ FunDef <$> funDecl <*> (keyword "is" *> stmtSeq <* keyword "end")

    structDef
      = try $ TypeDef <$> (keyword "struct" *> identifier <* keyword "is")
                      <*> (varDecl `sepBy` semicolon <* keyword "end")

    globalDef
      = try $ GlobalDef <$> varDecl <*> (whitespace *> char '=' *> expr)

program :: GenParser Char LocationData AnnotatedProgram
program = try $ do
  keyword "begin"
  defs <- many definition
  keyword "end"
  eof
  st <- getState
  return $ (defs, st)
