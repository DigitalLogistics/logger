{ mkDerivation, base, blaze-builder, bytestring, conduit
, conduit-extra, exceptions, fast-logger, lifted-base
, monad-control, monad-loops, mtl, resourcet, stdenv, stm
, stm-chans, template-haskell, text, transformers
, transformers-base
}:
mkDerivation {
  pname = "monad-logger-new";
  version = "0.4.0";
  src = ./.;
  buildDepends = [
    base blaze-builder bytestring conduit conduit-extra exceptions
    fast-logger lifted-base monad-control monad-loops mtl resourcet stm
    stm-chans template-haskell text transformers transformers-base
  ];
  homepage = "https://github.com/kazu-yamamoto/logger";
  description = "A class of monads which can log messages";
  license = stdenv.lib.licenses.mit;
}
