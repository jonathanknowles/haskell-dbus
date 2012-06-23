{-# LANGUAGE OverloadedStrings #-}

-- Copyright (C) 2009-2012 John Millikin <jmillikin@gmail.com>
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.

module DBus.Introspection
	( parseXml
	, formatXml
	
	, Object
	, object
	, objectPath
	, objectInterfaces
	, objectChildren
	
	, Interface
	, interface
	, interfaceName
	, interfaceMethods
	, interfaceSignals
	, interfaceProperties
	
	, Method
	, method
	, methodName
	, methodArgs
	
	, MethodArg
	, methodArg
	, methodArgName
	, methodArgType
	, methodArgDirection
	
	, Direction
	, directionIn
	, directionOut
	
	, Signal
	, signal
	, signalName
	, signalArgs
	
	, SignalArg
	, signalArg
	, signalArgName
	, signalArgType
	
	, Property
	, property
	, propertyName
	, propertyType
	, propertyAccess
	
	, Access
	, accessRead
	, accessWrite
	) where

import           Control.Monad ((>=>))
import           Control.Monad.ST (runST)
import           Data.List (isPrefixOf)
import qualified Data.STRef as ST
import qualified Data.Text
import           Data.Text (Text)
import qualified Data.Text.Encoding
import qualified Data.XML.Types as X
import qualified Text.XML.LibXML.SAX as SAX

import qualified DBus as T

data Object = Object
	{ objectPath :: T.ObjectPath
	, objectInterfaces :: [Interface]
	, objectChildren :: [Object]
	}
	deriving (Show, Eq)

object :: T.ObjectPath -> Object
object path = Object path [] []

data Interface = Interface
	{ interfaceName :: T.InterfaceName
	, interfaceMethods :: [Method]
	, interfaceSignals :: [Signal]
	, interfaceProperties :: [Property]
	}
	deriving (Show, Eq)

interface :: T.InterfaceName -> Interface
interface name = Interface name [] [] []

data Method = Method
	{ methodName :: T.MemberName
	, methodArgs :: [MethodArg]
	}
	deriving (Show, Eq)

method :: T.MemberName -> Method
method name = Method name []

data MethodArg = MethodArg
	{ methodArgName :: String
	, methodArgType :: T.Type
	, methodArgDirection :: Direction
	}
	deriving (Show, Eq)

methodArg :: String -> T.Type -> Direction -> MethodArg
methodArg = MethodArg

data Direction = In | Out
	deriving (Show, Eq)

directionIn :: Direction
directionIn = In

directionOut :: Direction
directionOut = Out

data Signal = Signal
	{ signalName :: T.MemberName
	, signalArgs :: [SignalArg]
	}
	deriving (Show, Eq)

signal :: T.MemberName -> Signal
signal name = Signal name []

data SignalArg = SignalArg
	{ signalArgName :: String
	, signalArgType :: T.Type
	}
	deriving (Show, Eq)

signalArg :: String -> T.Type -> SignalArg
signalArg = SignalArg

data Property = Property
	{ propertyName :: String
	, propertyType :: T.Type
	, propertyAccess :: [Access]
	}
	deriving (Show, Eq)

property :: String -> T.Type -> [Access] -> Property
property = Property

data Access = Read | Write
	deriving (Show, Eq)

accessRead :: Access
accessRead = Read

accessWrite :: Access
accessWrite = Write

parseXml :: T.ObjectPath -> String -> Maybe Object
parseXml path xml = do
	root <- parseElement (Data.Text.pack xml)
	parseRoot path root

parseElement :: Text -> Maybe X.Element
parseElement xml = runST $ do
	stackRef <- ST.newSTRef [([], [])]
	let onError _ = do
		ST.writeSTRef stackRef []
		return False
	let onBegin _ attrs = do
		ST.modifySTRef stackRef ((attrs, []):)
		return True
	let onEnd name = do
		stack <- ST.readSTRef stackRef
		let (attrs, children'):stack' = stack
		let e = X.Element name attrs (map X.NodeElement (reverse children'))
		let (pAttrs, pChildren):stack'' = stack'
		let parent = (pAttrs, e:pChildren)
		ST.writeSTRef stackRef (parent:stack'')
		return True
	
	p <- SAX.newParserST Nothing
	SAX.setCallback p SAX.parsedBeginElement onBegin
	SAX.setCallback p SAX.parsedEndElement onEnd
	SAX.setCallback p SAX.reportError onError
	SAX.parseBytes p (Data.Text.Encoding.encodeUtf8 xml)
	SAX.parseComplete p
	stack <- ST.readSTRef stackRef
	return $ case stack of
		[] -> Nothing
		(_, children'):_ -> Just (head children')

parseRoot :: T.ObjectPath -> X.Element -> Maybe Object
parseRoot defaultPath e = do
	path <- case X.attributeText "name" e of
		Nothing -> Just defaultPath
		Just x  -> T.parseObjectPath (Data.Text.unpack x)
	parseObject path e

parseChild :: T.ObjectPath -> X.Element -> Maybe Object
parseChild parentPath e = do
	let parentPath' = case T.formatObjectPath parentPath of
		"/" -> "/"
		x   -> x ++ "/"
	pathSegment <- X.attributeText "name" e
	path <- T.parseObjectPath (parentPath' ++ Data.Text.unpack pathSegment)
	parseObject path e

parseObject :: T.ObjectPath -> X.Element -> Maybe Object
parseObject path e | X.elementName e == "node" = do
	interfaces <- children parseInterface (X.isNamed "interface") e
	children' <- children (parseChild path) (X.isNamed "node") e
	return (Object path interfaces children')
parseObject _ _ = Nothing

parseInterface :: X.Element -> Maybe Interface
parseInterface e = do
	name <- T.parseInterfaceName =<< attributeString "name" e
	methods <- children parseMethod (X.isNamed "method") e
	signals <- children parseSignal (X.isNamed "signal") e
	properties <- children parseProperty (X.isNamed "property") e
	return (Interface name methods signals properties)

parseMethod :: X.Element -> Maybe Method
parseMethod e = do
	name <- T.parseMemberName =<< attributeString "name" e
	args <- children parseMethodArg (isArg ["in", "out", ""]) e
	return (Method name args)

parseSignal :: X.Element -> Maybe Signal
parseSignal e = do
	name <- T.parseMemberName =<< attributeString "name" e
	args <- children parseSignalArg (isArg ["out", ""]) e
	return (Signal name args)

parseType :: X.Element -> Maybe T.Signature
parseType e = do
	s <- attributeString "type" e
	T.parseSignature s

parseMethodArg :: X.Element -> Maybe MethodArg
parseMethodArg e = do
	sig <- parseType e
	let dir = case getattr "direction" e of
		"out" -> Out
		_ -> In
	case T.signatureTypes sig of
		[t] -> Just (MethodArg (getattr "name" e) t dir)
		_ -> Nothing

parseSignalArg :: X.Element -> Maybe SignalArg
parseSignalArg e = do
	sig <- parseType e
	case T.signatureTypes sig of
		[t] -> Just (SignalArg (getattr "name" e) t)
		_ -> Nothing

isArg :: [String] -> X.Element -> [X.Element]
isArg dirs = X.isNamed "arg" >=> checkDir where
	checkDir e = [e | getattr "direction" e `elem` dirs]

parseProperty :: X.Element -> Maybe Property
parseProperty e = do
	sig <- parseType e
	access <- case getattr "access" e of
		""          -> Just []
		"read"      -> Just [Read]
		"write"     -> Just [Write]
		"readwrite" -> Just [Read, Write]
		_           -> Nothing
	case T.signatureTypes sig of
		[t] -> Just (Property (getattr "name" e) t access)
		_ -> Nothing

getattr :: X.Name -> X.Element -> String
getattr name e = maybe "" Data.Text.unpack (X.attributeText name e)

children :: Monad m => (X.Element -> m b) -> (X.Element -> [X.Element]) -> X.Element -> m [b]
children f p = mapM f . concatMap p . X.elementChildren

newtype XmlWriter a = XmlWriter { runXmlWriter :: Maybe (a, String) }

instance Monad XmlWriter where
	return a = XmlWriter $ Just (a, "")
	m >>= f = XmlWriter $ do
		(a, w) <- runXmlWriter m
		(b, w') <- runXmlWriter (f a)
		return (b, w ++ w')

tell :: String -> XmlWriter ()
tell s = XmlWriter (Just ((), s))

formatXml :: Object -> Maybe String
formatXml obj = do
	(_, xml) <- runXmlWriter (writeRoot obj)
	return xml

writeRoot :: Object -> XmlWriter ()
writeRoot obj@(Object path _ _) = do
	tell "<!DOCTYPE node PUBLIC '-//freedesktop//DTD D-BUS Object Introspection 1.0//EN'"
	tell " 'http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd'>\n"
	writeObject (T.formatObjectPath path) obj

writeChild :: T.ObjectPath -> Object -> XmlWriter ()
writeChild parentPath obj@(Object path _ _) = write where
	path' = T.formatObjectPath path
	parent' = T.formatObjectPath  parentPath
	relpathM = if parent' `isPrefixOf` path'
		then Just $ if parent' == "/"
			then drop 1 path'
			else drop (length parent' + 1) path'
		else Nothing
	
	write = case relpathM of
		Just relpath -> writeObject relpath obj
		Nothing -> XmlWriter Nothing

writeObject :: String -> Object -> XmlWriter ()
writeObject path (Object fullPath interfaces children') = writeElement "node"
	[("name", path)] $ do
		mapM_ writeInterface interfaces
		mapM_ (writeChild fullPath) children'

writeInterface :: Interface -> XmlWriter ()
writeInterface (Interface name methods signals properties) = writeElement "interface"
	[("name", T.formatInterfaceName name)] $ do
		mapM_ writeMethod methods
		mapM_ writeSignal signals
		mapM_ writeProperty properties

writeMethod :: Method -> XmlWriter ()
writeMethod (Method name args) = writeElement "method"
	[("name", T.formatMemberName name)] $ do
		mapM_ writeMethodArg args

writeSignal :: Signal -> XmlWriter ()
writeSignal (Signal name args) = writeElement "signal"
	[("name", T.formatMemberName name)] $ do
		mapM_ writeSignalArg args

writeMethodArg :: MethodArg -> XmlWriter ()
writeMethodArg (MethodArg name t dir) = do
	sig <- case T.signature [t] of
		Just x -> return x
		Nothing -> XmlWriter Nothing
	let dirAttr = case dir of
		In -> "in"
		Out -> "out"
	writeEmptyElement "arg" $
		[ ("name", name)
		, ("type", T.formatSignature sig)
		, ("direction", dirAttr)
		]

writeSignalArg :: SignalArg -> XmlWriter ()
writeSignalArg (SignalArg name t) = do
	sig <- case T.signature [t] of
		Just x -> return x
		Nothing -> XmlWriter Nothing
	writeEmptyElement "arg" $
		[ ("name", name)
		, ("type", T.formatSignature sig)
		]

writeProperty :: Property -> XmlWriter ()
writeProperty (Property name t access) = do
	sig <- case T.signature [t] of
		Just x -> return x
		Nothing -> XmlWriter Nothing
	writeEmptyElement "property"
		[ ("name", name)
		, ("type", T.formatSignature sig)
		, ("access", strAccess access)
		]

strAccess :: [Access] -> String
strAccess access = readS ++ writeS where
	readS = if elem Read access then "read" else ""
	writeS = if elem Write access then "write" else ""

attributeString :: X.Name -> X.Element -> Maybe String
attributeString name e = fmap Data.Text.unpack (X.attributeText name e)

writeElement :: String -> [(String, String)] -> XmlWriter () -> XmlWriter ()
writeElement name attrs content = do
	tell "<"
	tell name
	mapM_ writeAttribute attrs
	tell ">"
	content
	tell "</"
	tell name
	tell ">"

writeEmptyElement :: String -> [(String, String)] -> XmlWriter ()
writeEmptyElement name attrs = do
	tell "<"
	tell name
	mapM_ writeAttribute attrs
	tell "/>"

writeAttribute :: (String, String) -> XmlWriter ()
writeAttribute (name, content) = do
	tell " "
	tell name
	tell "='"
	tell (escape content)
	tell "'"

escape :: String -> String
escape = concatMap $ \c -> case c of
	'&' -> "&amp;"
	'<' -> "&lt;"
	'>' -> "&gt;"
	'"' -> "&quot;"
	'\'' -> "&apos;"
	_ -> [c]
