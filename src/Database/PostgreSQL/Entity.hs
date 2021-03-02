{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE Strict #-}
{-|
  Module      : Database.PostgreSQL.Entity
  Copyright   : © Clément Delafargue, 2018
                  Théophile Choutri, 2021
  License     : MIT
  Maintainer  : theophile@choutri.eu
  Stability   : stable

  A PostgreSQL database layer that does not get in your way.


  See the "Database.PostgreSQL.Entity.BlogPost" module for an example of a data-type implementing the 'Entity' typeclass.
-}
module Database.PostgreSQL.Entity where

import Data.Vector (Vector)
import qualified Data.Vector as V
import Database.PostgreSQL.Simple.FromRow (FromRow)
import Database.PostgreSQL.Simple.ToField (ToField)
import Database.PostgreSQL.Simple.ToRow (ToRow)
import Database.PostgreSQL.Simple.Types (Only (..), Query (..))
import Database.PostgreSQL.Transact (DBT)

import Database.PostgreSQL.Entity.DBT (QueryNature (..), execute, query, queryOne, query_)

-- $setup
-- >>> :set -XOverloadedStrings
-- >>> :set -XOverloadedLists
-- >>> :set -XTypeApplications
-- >>> import Database.PostgreSQL.Entity
-- >>> import Database.PostgreSQL.Entity.BlogPost

-- * Class 

-- | An 'Entity' stores information about the structure of a database table, and in particular:
--
-- * Its name
-- * Its primary key
-- * The fields it contains
--
-- When using the functions provided by this library, you will need to provide Type Applications in order to tell
-- the compiler which 'Entity' you are referring to.
--
-- This library aims to be a thin layer between that sits between rigid ORMs and hand-rolled SQL query strings.
-- Here is its philosophy:
-- 
-- * The serialisation\/deserialisation part is left to the consumer, so you have to go with your own FromRow\/ToRow instances.
-- You are encouraged to adopt data types that model your business, rather than restrict yourself with the
-- limits of what a SQL schema can represent, and use a data access object that can easily be serialised and deserialised
-- in a SQL schema, to and from which you will morph your business data-types.
--
-- * Escape hatches are provided at every level. The types that are manipulated are 'Query' for which an IsString instance
-- exists. Don't force yourself to use the higher-level API if the combinators work for you, and if those don't either,
-- Just Write SQL™.
--
-- @since 0.0.1.0
class Entity e where
  -- | The name of the table in the PostgreSQL database.
  tableName  :: Text
  -- | The name of the primary key for the table.
  primaryKey :: Field
  -- | The fields of the table.
  fields     :: Vector Field

-- | A wrapper for table fields, with a very convenient 'IsString' instance.
--
-- @since 0.0.1.0
data Field
  = Field { fieldName :: Text
            -- ^ The name of the field in the database schema
          , fieldType :: Maybe Text
            -- ^ An optional postgresql type for which we need to be explicit, like @uuid[]@
          }
  deriving stock (Eq, Show)

-- | @since 0.0.1.0
instance IsString Field where
  fromString n = Field (toText n) Nothing

-- * High-level API

-- | Select an entity by its primary key.
--
-- @since 0.0.1.0
selectById :: forall e value m.
           (Entity e, FromRow e, ToField value, MonadIO m)
           => value -> DBT m e
selectById value = selectOneByField (primaryKey @e) value

-- | Select precisely __one__ entity by a provided field.
--
-- @since 0.0.1.0
selectOneByField :: forall e value m.
                 (Entity e, FromRow e, ToField value, MonadIO m)
                 => Field -> value -> DBT m e
selectOneByField f value = queryOne Select (_selectWhere @e [f]) (Only value)

-- | Select potentially many entities by a provided field.
--
-- @since 0.0.1.0
selectManyByField :: forall e value m.
                  (Entity e, FromRow e, ToField value, MonadIO m)
                  => Field -> value -> DBT m (Vector e)
selectManyByField f value = query Select (_selectWhere @e [f]) (Only value)

-- | Perform a INNER JOIN between two entities
--
-- @since 0.0.1.0
crossSelectById :: forall e1 e2 m.
                (Entity e1, Entity e2, FromRow e1, MonadIO m)
                => DBT m (Vector e1)
crossSelectById = query_ Select (_crossSelect @e1 @e2)

-- | Insert an entity.
--
-- @since 0.0.1.0
insert :: forall e values m.
       (Entity e, ToRow values, MonadIO m)
       => values -> DBT m ()
insert fs = void $ execute Insert (_insert @e) fs

-- | Delete an entity according to its primary key.
--
-- @since 0.0.1.0
delete :: forall e values m.
       (Entity e, ToRow values, MonadIO m)
       => values -> DBT m ()
delete values = void $ execute Delete (_delete @e) values

-- | Delete an entity according to a provided field.
--
-- @since 0.0.1.0
deleteByField :: forall e values m.
       (Entity e, ToRow values, MonadIO m)
       => Vector Field -> values -> DBT m ()
deleteByField fs values = void $ execute Delete (_deleteWhere @e fs) values

-- * SQL combinators API

-- | Produce a SELECT statement for a given entity.
--
-- __Examples__
--
-- >>> _select @BlogPost
-- "SELECT blogposts.\"blogpost_id\", blogposts.\"author_id\", blogposts.\"uuid_list\", blogposts.\"title\", blogposts.\"content\", blogposts.\"created_at\" FROM \"blogposts\""
--
-- @since 0.0.1.0
_select :: forall e. Entity e => Query
_select = fromText $ "SELECT " <> expandQualifiedFields @e <> " FROM " <> quoteName (tableName @e)

-- | Produce a SELECT statement with explicit fields for a given entity
--
-- __Examples__
--
-- >>> _selectWithFields @BlogPost ["blogpost_id", "created_at"]
-- "SELECT blogposts.\"blogpost_id\", blogposts.\"created_at\" FROM \"blogposts\""
--
-- @since 0.0.1.0
_selectWithFields :: forall e. Entity e => Vector Field -> Query
_selectWithFields fs = fromText $ "SELECT " <> expandQualifiedFields_ fs tn <> " FROM " <> quoteName tn
  where tn = tableName @e

-- | Produce a WHERE clause, given a vector of fields.
--
-- It is most useful composed with a '_select' or '_delete', which is why these two combinations have their dedicated functions,
-- but the user is free to compose their own queries.
--
-- The 'Entity' constraint is required for '_where' in order to get any type annotation that was given in the schema, as well as to
-- filter out unexisting fields.
--
-- __Examples__
--
-- >>> _select @BlogPost <> _where @BlogPost ["blogpost_id"]
-- "SELECT blogposts.\"blogpost_id\", blogposts.\"author_id\", blogposts.\"uuid_list\", blogposts.\"title\", blogposts.\"content\", blogposts.\"created_at\" FROM \"blogposts\" WHERE \"blogpost_id\" = ?"
--
-- >>> _select @BlogPost <> _where @BlogPost ["uuid_list"]
-- "SELECT blogposts.\"blogpost_id\", blogposts.\"author_id\", blogposts.\"uuid_list\", blogposts.\"title\", blogposts.\"content\", blogposts.\"created_at\" FROM \"blogposts\" WHERE \"uuid_list\" = ?::uuid[]"
--
-- @since 0.0.1.0
_where :: forall e. Entity e => Vector Field -> Query
_where fs' = fromText $ " WHERE " <> clauseFields
  where
    fs = V.filter (\f -> fieldName f `elem` fieldNames) (fields @e)
    fieldNames = fmap fieldName fs'
    clauseFields = fold $ intercalateVector " AND " (fmap placeHolder fs)

-- | Produce a SELECT expression for a given entity and fields.
--
-- __Examples__
--
-- >>> _selectWhere @BlogPost ["author_id"]
-- "SELECT blogposts.\"blogpost_id\", blogposts.\"author_id\", blogposts.\"uuid_list\", blogposts.\"title\", blogposts.\"content\", blogposts.\"created_at\" FROM \"blogposts\" WHERE \"author_id\" = ?"
--
-- @since 0.0.1.0
_selectWhere :: forall e. Entity e => Vector Field -> Query
_selectWhere fs = _select @e <> _where @e fs

-- | Produce a "SELECT FROM" over two entities.
--
-- __Examples__
--
-- >>> _crossSelect @BlogPost @Author
-- "SELECT blogposts.\"blogpost_id\", blogposts.\"author_id\", blogposts.\"uuid_list\", blogposts.\"title\", blogposts.\"content\", blogposts.\"created_at\", authors.\"author_id\", authors.\"name\", authors.\"created_at\" FROM \"blogposts\" INNER JOIN \"authors\" USING(author_id)"
--
-- @since 0.0.1.0
_crossSelect :: forall e1 e2. (Entity e1, Entity e2) => Query
_crossSelect = fromText $ "SELECT " <> expandQualifiedFields @e1 <> ", "
                                    <> expandQualifiedFields @e2 <>
                           " FROM " <> quoteName (tableName @e1)
                           <> queryToText (_innerJoin @e2 (primaryKey @e2))

-- | Produce a "INNER JOIN … USING(…)" fragment.
--
-- __Examples__
--
-- >>> _innerJoin @BlogPost "author_id"
-- " INNER JOIN \"blogposts\" USING(author_id)"
--
-- @since 0.0.1.0
_innerJoin :: forall e. (Entity e) => Field -> Query
_innerJoin f = fromText $ " INNER JOIN " <> quoteName (tableName @e)
                          <> " USING(" <> fieldName f <> ")"

-- | Produce a "SELECT [table1_fields, table2_fields] FROM table1 INNER JOIN table2 USING(table2_pk)"
--
-- __Examples__
--
-- >>> _crossSelectWithFields @BlogPost @Author ["title"] ["name"]
-- "SELECT blogposts.\"title\", authors.\"name\" FROM \"blogposts\" INNER JOIN \"authors\" USING(author_id)"
--
-- @since 0.0.1.0
_crossSelectWithFields :: forall e1 e2. (Entity e1, Entity e2)
                   => Vector Field -> Vector Field -> Query
_crossSelectWithFields fs1 fs2 =
  fromText $ "SELECT " <> expandQualifiedFields_ fs1 tn1
    <> ", " <> expandQualifiedFields_ fs2 tn2
    <> " FROM " <> quoteName (tableName @e1)
    <> queryToText (_innerJoin @e2 (primaryKey @e2))
  where
    tn1 = tableName @e1
    tn2 = tableName @e2

-- | Produce an INSERT statement for the given entity.
--
-- __Examples__
--
-- >>> _insert @BlogPost
-- "INSERT INTO \"blogposts\" (\"blogpost_id\", \"author_id\", \"uuid_list\", \"title\", \"content\", \"created_at\") VALUES (?, ?, ?::uuid[], ?, ?, ?)"
--
-- @since 0.0.1.0
_insert :: forall e. Entity e => Query
_insert = fromText $ "INSERT INTO " <> quoteName (tableName @e) <> " " <> fs <> " VALUES " <> ps
  where
    fs = inParens (expandFields @e)
    ps = inParens (generatePlaceholders $ fields @e)

-- | Produce a DELETE statement for the given entity, with a match on the Primary Key
--
-- __Examples__
--
-- >>> _delete @BlogPost
-- "DELETE FROM \"blogposts\" WHERE \"blogpost_id\" = ?"
--
-- @since 0.0.1.0
_delete :: forall e. Entity e => Query
_delete = fromText ("DELETE FROM " <> quoteName (tableName @e)) <> _where @e [primaryKey @e]

-- | Produce a DELETE statement for the given entity and fields
--
-- __Examples__
--
-- >>> _deleteWhere @BlogPost ["title", "created_at"]
-- "DELETE FROM blogposts WHERE \"title\" = ? AND \"created_at\" = ?"
--
-- @since 0.0.1.0
_deleteWhere :: forall e. Entity e => Vector Field -> Query
_deleteWhere fs = fromText ("DELETE FROM " <> (tableName @e)) <> _where @e fs

-- * Helpers

-- | A infix helper to declare a table field with an explicit type annotation.
--
-- __Examples__
--
-- >>> "author_id" `withType` "uuid[]"
-- Field {fieldName = "author_id", fieldType = Just "uuid[]"}
--
-- @since 0.0.1.0
withType :: Field -> Text -> Field
withType (Field n _) t = Field n (Just t)

-- | Wrap the given text between parentheses
--
-- __Examples__
--
-- >>> inParens "wrap me!"
-- "(wrap me!)"
--
-- @since 0.0.1.0
inParens :: Text -> Text
inParens t = "(" <> t <> ")"

-- | Wrap the given text between double quotes
--
-- __Examples__
--
-- >>> quoteName "meow."
-- "\"meow.\""
--
-- @since 0.0.1.0
quoteName :: Text -> Text
quoteName n = "\"" <> n <> "\""

-- | Produce a comma-separated list of an entity's fields.
--
-- __Examples__
--
-- >>> expandFields @BlogPost
-- "\"blogpost_id\", \"author_id\", \"uuid_list\", \"title\", \"content\", \"created_at\""
--
-- @since 0.0.1.0
expandFields :: forall e. Entity e => Text
expandFields = V.foldl1' (\element acc -> element <> ", " <> acc) (quoteName . fieldName <$> fields @e)

-- | Produce a comma-separated list of an entity's fields, qualified with the table name
--
-- __Examples__
--
-- >>> expandQualifiedFields @BlogPost
-- "blogposts.\"blogpost_id\", blogposts.\"author_id\", blogposts.\"uuid_list\", blogposts.\"title\", blogposts.\"content\", blogposts.\"created_at\""
--
-- @since 0.0.1.0
expandQualifiedFields :: forall e. Entity e => Text
expandQualifiedFields = expandQualifiedFields_ (fields @e) prefix
  where
    prefix = tableName @e

-- | Produce a comma-separated list of an entity's 'fields', qualified with an arbitrary prefix
--
-- __Examples__
--
-- >>> expandQualifiedFields_ (fields @BlogPost) "legacy"
-- "legacy.\"blogpost_id\", legacy.\"author_id\", legacy.\"uuid_list\", legacy.\"title\", legacy.\"content\", legacy.\"created_at\""
--
-- @since 0.0.1.0
expandQualifiedFields_ :: Vector Field -> Text -> Text
expandQualifiedFields_ fs prefix = V.foldl1' (\element acc -> element <> ", " <> acc) fs'
  where
    fs' = fieldName <$> prefixFields prefix fs

-- | Take a prefix and a vector of fields, and qualifies each field with the prefix
--
-- __Examples__
--
-- >>> prefixFields "legacy" (fields @BlogPost)
-- [Field {fieldName = "legacy.\"blogpost_id\"", fieldType = Nothing},Field {fieldName = "legacy.\"author_id\"", fieldType = Nothing},Field {fieldName = "legacy.\"uuid_list\"", fieldType = Just "uuid[]"},Field {fieldName = "legacy.\"title\"", fieldType = Nothing},Field {fieldName = "legacy.\"content\"", fieldType = Nothing},Field {fieldName = "legacy.\"created_at\"", fieldType = Nothing}]
--
-- @since 0.0.1.0
prefixFields :: Text -> Vector Field -> Vector Field
prefixFields p fs = fmap (\(Field f t) -> Field (p <> "." <> quoteName f) t) fs

-- | Produce a placeholder of the form @\"field\" = ?@
--
-- __Examples__
--
-- >>> placeHolder "id"
-- "\"id\" = ?"
--
-- >>> placeHolder $ Field "ids" (Just "uuid[]")
-- "\"ids\" = ?::uuid[]"
--
-- >>> fmap placeHolder $ fields @BlogPost
-- ["\"blogpost_id\" = ?","\"author_id\" = ?","\"uuid_list\" = ?::uuid[]","\"title\" = ?","\"content\" = ?","\"created_at\" = ?"]
--
-- @since 0.0.1.0
placeHolder :: Field -> Text
placeHolder (Field f Nothing)  = quoteName f <> " = ?"
placeHolder (Field f (Just t)) = quoteName f <> " = ?::" <> t

-- | Generate an appropriate number of “?” placeholders given a vector of fields
--
-- __Examples__
--
-- >>> generatePlaceholders $ fields @BlogPost
-- "?, ?, ?::uuid[], ?, ?, ?"
--
-- @since 0.0.1.0
generatePlaceholders :: Vector Field -> Text
generatePlaceholders vf = fold $ intercalateVector ", " $ fmap ph vf
  where
    ph (Field _ t) = maybe "?" (\t' -> "?::" <> t') t

-- | Since the 'Query' type has an 'IsString' instance, the process of converting from 'Text' to 'String' to 'Query' is
-- factored into this function
--
-- @since 0.0.1.0
fromText :: Text -> Query
fromText = fromString . toString

-- | For cases where combinator composition is tricky, we can safely get back to a 'Text' string from a 'Query'
--
-- @since 0.0.1.0
queryToText :: Query -> Text
queryToText = decodeUtf8 . fromQuery

-- | The 'intercalateVector' function takes a Text and a Vector Text and concatenates the vector after interspersing
-- the first argument between each element of the list.
--
-- __Examples__
--
-- >>> intercalateVector "~" []
-- []
--
-- >>> intercalateVector "~" ["nyan"]
-- ["nyan"]
--
-- >>> intercalateVector "~" ["nyan", "nyan", "nyan"]
-- ["nyan","~","nyan","~","nyan"]
--
-- @since 0.0.1.0
intercalateVector :: Text -> Vector Text -> Vector Text
intercalateVector sep vt | V.null vt = vt
                         | otherwise = V.cons x (go xs)
  where
    (x,xs) = (V.head vt, V.tail vt)
    go :: Vector Text -> Vector Text
    go ys | V.null ys = ys
          | otherwise = V.cons sep (V.cons (V.head ys) (go (V.tail ys)))
