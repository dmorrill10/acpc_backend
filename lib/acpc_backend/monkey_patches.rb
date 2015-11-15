module AcpcBackend
  module MonkeyPatches
    module ConversionToEnglish
      def to_english
        gsub '_', ' '
      end
    end
    module StringToEnglishExtension
      refine String do
        include ConversionToEnglish
      end
    end
    module SymbolToEnglishExtension
      refine Symbol do
        include ConversionToEnglish
      end
    end
  end
end
end
