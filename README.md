# The `dotapp` Package Provider #

This module, heavily inspired by the built-in `appdmg` provider, downloads and
installs applications on OS X systems.  Unlike its predecessors, the `dotapp`
provider can monitor the specified `source` for updates, does not require
superuser privileges to function, and can install from a variety of package
formats.

## Example ##

``` puppet
package { "Google Chrome.app":
  provider => dotapp,
  source   => "https://dl.google.com/chrome/mac/stable/GoogleChrome.dmg",
}
```

## Constraints ##

* The resource `name` must match the name of the application from the package
* The `source` parameter must, after any HTTP redirection, refer to a file of a
  supported format
  * The currently supported formats are `dmg`, `zip`, `tar`, `tbz`, and `tar.gz`

## Caveats ##

The `dotapp` provider will only installed the named application from the source
package, making it unsuitable as a drop-in replacement for the `appdmg`
provider in some cases.
