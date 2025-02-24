{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes       #-}
module Auth.Biscuit.Example where

import           Data.ByteString (ByteString)
import           Data.Functor    (($>))
import           Data.Maybe      (fromMaybe)
import           Data.Time       (getCurrentTime)

import           Auth.Biscuit

privateKey' :: SecretKey
privateKey' = fromMaybe (error "Error parsing private key") $ parseSecretKeyHex "todo"

publicKey' :: PublicKey
publicKey' = fromMaybe (error "Error parsing public key") $ parsePublicKeyHex "todo"

creation :: IO ByteString
creation = do
  let authority = [block|
       // toto
       resource("file1");
       |]
  biscuit <- mkBiscuit privateKey' authority
  let block1 = [block|check if current_time($time), $time < 2021-05-08T00:00:00Z;|]
  newBiscuit <- addBlock block1 biscuit
  pure $ serializeB64 newBiscuit

verification :: ByteString -> IO Bool
verification serialized = do
  now <- getCurrentTime
  biscuit <- either (fail . show) pure $ parseB64 publicKey' serialized
  let authorizer' = [authorizer|current_time(${now});|]
  result <- authorizeBiscuit biscuit authorizer'
  case result of
    Left e  -> print e $> False
    Right _ -> pure True
