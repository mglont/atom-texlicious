_ = require 'underscore-plus'
path = require 'path'

module.exports =
class Builder
  constructor: ->
    @envPathKey = switch process.platform
      when 'win32' then 'Path'
      else 'PATH'

  setChildProcessEnv: (shouldWatch) ->
    env = _.clone(process.env)
    env[@envPathKey] = childPath if childPath = @constructPath()
    env['TEXINPUTS']  = atom.config.get('texlicious.texInputs') ? ''
    env['timeout'] = 60000 if shouldWatch?
    options = env: env
    options.env['max_print_line'] = 1000  # Max log file line length.
    options

  constructPath: ->
    texPath = atom.config.get('texlicious.texPath')?.trim()
    texPath = @defaultTexPath() unless texPath?.length
    texPath = texPath.replace('$PATH', process.env[@envPathKey])

  defaultTexPath: ->
    switch process.platform
      when 'win32'
        '$PATH;C:\\texlive\\2014\\bin\\win32'
      else
        '$PATH:/usr/texbin'