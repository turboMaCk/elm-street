{- | Pretty-printing functions for @Decoder.elm@ module.
Also contains decoders for common types which go to the @ElmStreet.elm@ module.
-}

module Elm.Print.Decoder
       ( prettyShowDecoder

         -- * Standard missing decoders
       , decodeEnum
       , decodeChar
       , decodeEither
       , decodePair
       , decodeTriple
       ) where

import Data.List.NonEmpty (toList)
import Data.Text (Text)
import Data.Text.Prettyprint.Doc (Doc, colon, concatWith, dquotes, emptyDoc, equals, line, nest,
                                  parens, pretty, surround, vsep, (<+>))

import Elm.Ast (ElmAlias (..), ElmConstructor (..), ElmDefinition (..), ElmPrim (..),
                ElmRecordField (..), ElmType (..), TypeName (..), TypeRef (..), isEnum)
import Elm.Print.Common (arrow, mkQualified, showDoc, typeWithVarsDoc, wrapParens)

import qualified Data.List.NonEmpty as NE
import qualified Data.Text as T


----------------------------------------------------------------------------
-- Decode
----------------------------------------------------------------------------

{- |

__Sum Types:__

Haskell type

@
type User
    = Foo
    | Bar String Int
@

Encoded JSON on Haskell side

@
    [ { "tag" : "Foo"
      }
    , { "tag" : "Bar"
      , "contents" : ["asd", 42, "qwerty"]
      }
    ]
@

Elm decoder

@
userDecoder : Decoder User
userDecoder =
    let decide : String -> Decoder User
        decide x = case x of
            \"Foo\" -> D.succeed Foo
            \"Bar\" -> D.field "contents" <| D.map2 Bar (D.index 0 D.string) (D.index 1 D.int)
            x -> D.fail <| "There is no constructor for User type:" ++ x
    in D.andThen decide (D.field "tag" D.string)
@

-}
prettyShowDecoder :: ElmDefinition -> Text
prettyShowDecoder def = showDoc $ case def of
    DefAlias elmAlias -> aliasDecoderDoc elmAlias
    DefType elmType   -> typeDecoderDoc elmType
    DefPrim _         -> emptyDoc

aliasDecoderDoc :: ElmAlias -> Doc ann
aliasDecoderDoc ElmAlias{..} =
    decoderDef elmAliasName []
    <> line
    <> if elmAliasIsNewtype
       then newtypeDecoder
       else recordDecoder
  where
    newtypeDecoder :: Doc ann
    newtypeDecoder = name <+> "D.map" <+> qualifiedAliasName
        <+> typeRefDecoder (elmRecordFieldType $ NE.head elmAliasFields)

    recordDecoder :: Doc ann
    recordDecoder = nest 4
        $ vsep
        $ (name <+> "D.succeed" <+> qualifiedAliasName)
        : map fieldDecode (toList elmAliasFields)

    name :: Doc ann
    name = decoderName elmAliasName <+> equals

    qualifiedAliasName :: Doc ann
    qualifiedAliasName = mkQualified elmAliasName

    fieldDecode :: ElmRecordField -> Doc ann
    fieldDecode ElmRecordField{..} = case elmRecordFieldType of
        RefPrim ElmUnit -> "|> D.hardcoded ()"
        t -> "|> required"
            <+> dquotes (pretty elmRecordFieldName)
            <+> typeRefDecoder t

typeDecoderDoc :: ElmType -> Doc ann
typeDecoderDoc  t@ElmType{..} =
    -- function defenition: @encodeTypeName : TypeName -> Value@.
       decoderDef elmTypeName elmTypeVars
    <> line
    <> if isEnum t
       -- if this is Enum just using the read instance we wrote.
       then enumDecoder
       else if elmTypeIsNewtype
            -- if it newtype then wrap decoder for the field
            then newtypeDecoder
            -- If it sum type then it should look like: @{"tag": "Foo", "contents" : ["string", 1]}@
            else sumDecoder
  where
    name :: Doc ann
    name = decoderName elmTypeName <+> equals

    typeName :: Doc ann
    typeName = pretty elmTypeName

    qualifiedTypeName :: Doc ann
    qualifiedTypeName = mkQualified elmTypeName

    enumDecoder :: Doc ann
    enumDecoder = name <+> "elmStreetDecodeEnum T.read" <> typeName

    newtypeDecoder :: Doc ann
    newtypeDecoder = name <+> "D.map" <+> qualifiedTypeName <+> fieldDecoderDoc
      where
        fieldDecoderDoc :: Doc ann
        fieldDecoderDoc = case elmConstructorFields $ NE.head elmTypeConstructors of
            []    -> "(D.fail \"Unknown field type of the newtype constructor\")"
            f : _ -> typeRefDecoder f

    sumDecoder :: Doc ann
    sumDecoder = nest 4 $ vsep
        [ name
        , nest 4 (vsep $ ("let decide : String -> Decoder" <+> qualifiedTypeName) :
            [ nest 4
                ( vsep $ "decide x = case x of"
                : map cases (toList elmTypeConstructors)
               ++ ["c -> D.fail <|" <+> dquotes (typeName <+> "doesn't have such constructor: ") <+> "++ c"]
                )
            ])
        , "in D.andThen decide (D.field \"tag\" D.string)"
        ]

    cases :: ElmConstructor -> Doc ann
    cases ElmConstructor{..} = dquotes cName <+> arrow <+>
        case elmConstructorFields of
            []  -> "D.succeed" <+> qualifiedConName
            [f] -> "D.field \"contents\" <| D.map" <+> qualifiedConName <+> typeRefDecoder f
            l   -> "D.field \"contents\" <| D.map" <> mapNum (length l) <+> qualifiedConName <+> createIndexes
      where
        cName :: Doc ann
        cName = pretty elmConstructorName

        qualifiedConName :: Doc ann
        qualifiedConName = mkQualified elmConstructorName

        -- Use function map, map2, map3 etc.
        mapNum :: Int -> Doc ann
        mapNum 1 = emptyDoc
        mapNum i = pretty i

        createIndexes :: Doc ann
        createIndexes = concatWith (surround " ") $ zipWith oneField [0..] elmConstructorFields

        -- create @(D.index 0 D.string)@ etc.
        oneField :: Int -> TypeRef -> Doc ann
        oneField i typeRef = parens $ "D.index" <+> pretty i <+> typeRefDecoder typeRef

-- | Converts the reference to the existing type to the corresponding decoder.
typeRefDecoder :: TypeRef -> Doc ann
typeRefDecoder (RefCustom TypeName{..}) = "decode" <> pretty (T.takeWhile (/= ' ') unTypeName)
typeRefDecoder (RefPrim elmPrim) = case elmPrim of
    ElmUnit         -> "(D.map (always ()) (D.list D.string))"
    ElmNever        -> "(D.fail \"Never is not possible\")"
    ElmBool         -> "D.bool"
    ElmChar         -> "elmStreetDecodeChar"
    ElmInt          -> "D.int"
    ElmFloat        -> "D.float"
    ElmString       -> "D.string"
    ElmTime         -> "Iso.decoder"
    ElmMaybe t      -> parens $ "nullable" <+> typeRefDecoder t
    ElmResult l r   -> parens $ "elmStreetDecodeEither" <+> typeRefDecoder l <+> typeRefDecoder r
    ElmPair a b     -> parens $ "elmStreetDecodePair" <+> typeRefDecoder a <+> typeRefDecoder b
    ElmTriple a b c -> parens $ "elmStreetDecodeTriple" <+> typeRefDecoder a <+> typeRefDecoder b <+> typeRefDecoder c
    ElmList l       -> parens $ "D.list" <+> typeRefDecoder l

-- | The definition of the @decodeTYPENAME@ function.
decoderDef
    :: Text  -- ^ Type name
    -> [Text] -- ^ List of type variables
    -> Doc ann
decoderDef typeName vars =
    decoderName typeName <+> colon <+> "Decoder" <+> wrapParens (typeWithVarsDoc typeName vars)

-- | Create the name of the decoder function.
decoderName :: Text -> Doc ann
decoderName typeName = "decode" <> pretty typeName

-- | @JSON@ decoder Elm help function for Enum types.
decodeEnum :: Text
decodeEnum = T.unlines
    [ "decodeStr : (String -> Maybe a) -> String -> Decoder a"
    , "decodeStr readX x = case readX x of"
    , "    Just a  -> D.succeed a"
    , "    Nothing -> D.fail \"Constructor not matched\""
    , ""
    , "elmStreetDecodeEnum : (String -> Maybe a) -> Decoder a"
    , "elmStreetDecodeEnum r = D.andThen (decodeStr r) D.string"
    ]

-- | @JSON@ decoder Elm help function for 'Char's.
decodeChar :: Text
decodeChar = T.unlines
    [ "elmStreetDecodeChar : Decoder Char"
    , "elmStreetDecodeChar = D.andThen (decodeStr (Maybe.map Tuple.first << String.uncons)) D.string"
    ]

-- | @JSON@ decoder Elm help function for 'Either's.
decodeEither :: Text
decodeEither = T.unlines
    [ "elmStreetDecodeEither : Decoder a -> Decoder b -> Decoder (Result a b)"
    , "elmStreetDecodeEither decA decB = D.oneOf "
    , "    [ D.field \"Left\"  (D.map Err decA)"
    , "    , D.field \"Right\" (D.map Ok decB)"
    , "    ]"
    ]

-- | @JSON@ decoder Elm help function for 2-tuples.
decodePair :: Text
decodePair = T.unlines
    [ "elmStreetDecodePair : Decoder a -> Decoder b -> Decoder (a, b)"
    , "elmStreetDecodePair decA decB = D.map2 Tuple.pair (D.index 0 decA) (D.index 1 decB)"
    ]

-- | @JSON@ decoder Elm help function for 3-tuples.
decodeTriple :: Text
decodeTriple = T.unlines
    [ "elmStreetDecodeTriple : Decoder a -> Decoder b -> Decoder c -> Decoder (a, b, c)"
    , "elmStreetDecodeTriple decA decB decC = D.map3 (\\a b c -> (a,b,c)) (D.index 0 decA) (D.index 1 decB) (D.index 2 decC)"
    ]
