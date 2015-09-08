{-# LANGUAGE FlexibleInstances,
             MultiParamTypeClasses #-}

module GLua.PSParser where

import GLua.TokenTypes
import GLua.AG.Token
import GLua.AG.AST
import qualified GLua.Lexer as Lex

import Text.Parsec
import Text.Parsec.Prim
import Text.Parsec.Combinator
import Text.Parsec.Pos
import Text.ParserCombinators.UU.BasicInstances(LineColPos(..)) -- for LineColPos

type AParser = Parsec [MToken] ()

-- | Execute a parser
execAParser :: SourceName -> AParser a -> [MToken] -> Either ParseError a
execAParser name p mts = parse p name mts

-- | Parse a string directly
parseFromString :: AParser a -> String -> Either ParseError a
parseFromString p = execAParser "source.lua" p . filter (not . isWhitespace) . fst . Lex.execParseTokens

-- | Parse Garry's mod Lua tokens to an abstract syntax tree.
-- Also returns parse errors
parseGLua :: [MToken] -> Either ParseError AST
parseGLua mts = let (cms, ts) = splitComments . filter (not . isWhitespace) $ mts in
                 execAParser "source.lua" (parseChunk cms) ts

-- | LineColPos to SourcePos
lcp2sp :: LineColPos -> SourcePos
lcp2sp (LineColPos l c _) = newPos "source.lua" l c

sp2lcp :: SourcePos -> LineColPos
sp2lcp pos = LineColPos (sourceLine pos) (sourceColumn pos) 0

-- | Update a SourcePos with an MToken
updatePosMToken :: SourcePos -> MToken -> [MToken] -> SourcePos
updatePosMToken _ (MToken p _) _ = lcp2sp p

-- | Match a token
pMTok :: Token -> AParser MToken
pMTok tok = tokenPrim show updatePosMToken testMToken
    where
        testMToken :: MToken -> Maybe MToken
        testMToken mt@(MToken _ t) = if t == tok then Just mt else Nothing

-- Tokens that satisfy a condition
pMSatisfy :: (MToken -> Bool) -> AParser MToken
pMSatisfy cond = tokenPrim show updatePosMToken testMToken
    where
        testMToken :: MToken -> Maybe MToken
        testMToken mt = if cond mt then Just mt else Nothing

-- | Get the source position
pPos :: AParser LineColPos
pPos = sp2lcp <$> getPosition

nope :: AParser a
nope = parserFail "Not implemented yet"

-- | Parses the full AST
-- Its first parameter contains all comments
-- Assumes the mtokens fed to the AParser have no comments
parseChunk :: [MToken] -> AParser AST
parseChunk cms = AST cms <$> parseBlock

-- | Parse a block with an optional return value
parseBlock :: AParser Block
parseBlock = Block <$> pInterleaved (pMTok Semicolon) parseMStat <*> (parseReturn <|> return NoReturn)

parseMStat :: AParser MStat
parseMStat = MStat <$> pPos <*> parseStat

-- | Parser that is interleaved with 0 or more of the other parser
pInterleaved :: AParser a -> AParser b -> AParser [b]
pInterleaved sep q = many sep *> many (q <* many sep)

-- | Parse a return value
parseReturn :: AParser AReturn
parseReturn = AReturn <$> pPos <* pMTok Return <*> option [] parseExpressionList <* many (pMTok Semicolon)

-- | Label
parseLabel :: AParser MToken
parseLabel = pMSatisfy isLabel <?> "label"
    where
        isLabel :: MToken -> Bool
        isLabel (MToken _ (Label _)) = True
        isLabel _ = False

-- | Parse a single statement
parseStat :: AParser Stat
parseStat = nope

-- | Function name (includes dot indices and meta indices)
parseFuncName :: AParser FuncName
parseFuncName = (\a b c -> FuncName (a:b) c) <$> pName <*> many (pMTok Dot *> pName) <*>
                option Nothing (Just <$ pMTok Colon <*> pName) <?> "function name"

-- | Parse a number into an expression
parseNumber :: AParser Expr
parseNumber = (\(MToken _ (TNumber str)) -> ANumber str) <$> pMSatisfy isNumber <?> "number"
    where
        isNumber :: MToken -> Bool
        isNumber (MToken _ (TNumber _)) = True
        isNumber _ = False

-- | Parse any kind of string
parseString :: AParser MToken
parseString = pMSatisfy isString <?> "string"
    where
        isString :: MToken -> Bool
        isString (MToken _ (DQString _)) = True
        isString (MToken _ (SQString _)) = True
        isString (MToken _ (MLString _)) = True
        isString _ = False

-- | Parse an identifier
pName :: AParser MToken
pName = pMSatisfy isName <?> "identifier"
    where
        isName :: MToken -> Bool
        isName (MToken _ (Identifier _)) = True
        isName _ = False

-- | Parse a list of identifiers
parseNameList :: AParser [MToken]
parseNameList = sepBy1 pName (pMTok Comma)

-- | Parse variable list (var1, var2, var3)
parseVarList :: AParser [PrefixExp]
parseVarList = sepBy1 parseVar (pMTok Comma)

-- | Parse list of function parameters
parseParList :: AParser [MToken]
parseParList = option [] $ nameParam <|> vararg
    where
        vararg = (:[]) <$> pMTok VarArg <?> "..."
        nameParam = (:) <$> pName <*> moreParams <?> "parameter"
        moreParams = option [] $ pMTok Comma *> (nameParam <|> vararg)

-- | list of expressions
parseExpressionList :: AParser [MExpr]
parseExpressionList = sepBy1 parseExpression (pMTok Comma)

-- | Subexpressions, i.e. without operators
parseSubExpression :: AParser Expr
parseSubExpression = ANil <$ pMTok Nil <|>
                  AFalse <$ pMTok TFalse <|>
                  ATrue <$ pMTok TTrue <|>
                  parseNumber <|>
                  AString <$> parseString <|>
                  AVarArg <$ pMTok VarArg <|>
                  parseAnonymFunc <|>
                  APrefixExpr <$> parsePrefixExp <|>
                  ATableConstructor <$> parseTableConstructor

-- | Separate parser for anonymous function subexpression
parseAnonymFunc :: AParser Expr
parseAnonymFunc = AnonymousFunc <$
                   pMTok Function <*
                   pMTok LRound <*> parseParList <* pMTok RRound <*>
                   parseBlock <*
                   pMTok End

-- | Prefix expressions
-- can have any arbitrary list of expression suffixes
parsePrefixExp :: AParser PrefixExp
parsePrefixExp = pPrefixExp (many pPFExprSuffix)

-- | Prefix expressions
-- The suffixes define rules on the allowed suffixes
pPrefixExp :: AParser [PFExprSuffix] -> AParser PrefixExp
pPrefixExp suffixes = PFVar <$> pName <*> suffixes <|>
                      ExprVar <$ pMTok LRound <*> parseExpression <* pMTok RRound <*> suffixes

-- | Parse any expression suffix
pPFExprSuffix :: AParser PFExprSuffix
pPFExprSuffix = pPFExprCallSuffix <|> pPFExprIndexSuffix

-- | Parse an indexing expression suffix
pPFExprCallSuffix :: AParser PFExprSuffix
pPFExprCallSuffix = Call <$> parseArgs <|>
                    MetaCall <$ pMTok Colon <*> pName <*> parseArgs

-- | Parse an indexing expression suffix
pPFExprIndexSuffix :: AParser PFExprSuffix
pPFExprIndexSuffix = ExprIndex <$ pMTok LSquare <*> parseExpression <* pMTok RSquare <|>
                     DotIndex <$ pMTok Dot <*> pName

-- | Function calls are prefix expressions, but the last suffix MUST be either a function call or a metafunction call
pFunctionCall :: AParser PrefixExp
pFunctionCall = pPrefixExp suffixes
    where
        suffixes = concat <$> many1 ((\ix c -> ix ++ [c]) <$> many1 pPFExprIndexSuffix <*> pPFExprCallSuffix <|>
                                     (:[])                <$> pPFExprCallSuffix)

-- | single variable. Note: definition differs from reference to circumvent the left recursion
-- var ::= Name [{PFExprSuffix}* indexation] | '(' exp ')' {PFExprSuffix}* indexation
-- where "{PFExprSuffix}* indexation" is any arbitrary sequence of prefix expression suffixes that end with an indexation
parseVar :: AParser PrefixExp
parseVar = pPrefixExp suffixes
    where
        suffixes = concat <$> many ((\c ix -> c ++ [ix]) <$> many1 pPFExprCallSuffix <*> pPFExprIndexSuffix <|>
                                    (:[])                <$> pPFExprIndexSuffix)

-- | Parse chains of binary and unary operators
parseExpression :: AParser MExpr
parseExpression = nope <?> "expression"

-- | Arguments of a function call (including brackets)
parseArgs :: AParser Args
parseArgs = ListArgs <$ pMTok LRound <*> option [] parseExpressionList <* pMTok RRound <|>
            TableArg <$> parseTableConstructor <|>
            StringArg <$> parseString <?> "function arguments"

-- | Table constructor
parseTableConstructor :: AParser [Field]
parseTableConstructor = pMTok LCurly *> parseFieldList <* pMTok RCurly

-- | A list of table entries
-- Grammar: field {separator field} [separator]
parseFieldList :: AParser [Field]
parseFieldList = nope

-- | Field separator
parseFieldSep :: AParser MToken
parseFieldSep = pMTok Comma <|> pMTok Semicolon
