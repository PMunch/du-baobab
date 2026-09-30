# Package

version       = "0.1.0"
author        = "PMunch"
description   = "Interactive Baobab-style disk usage visualization of du output"
license       = "MIT"
srcDir        = "src"
bin           = @["du_baobab"]


# Dependencies

requires "nim >= 2.2.0"
requires "owlkettle >= 3.1.0"
