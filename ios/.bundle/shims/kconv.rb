# Shim: CFPropertyList 3.0.8 does `require 'kconv'` but never uses Kconv.
# Ruby 3.4 dropped kconv from stdlib and no replacement gem exists.
# This empty shim satisfies the require so `pod install` works.
