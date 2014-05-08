_ = window?._ ? self?._ ? global?._ ? require 'lodash'  # rely on lodash existing, since it busts CodeCombat to browserify it--TODO

jshint = require('jshint').JSHINT
esprima = require 'esprima'  # getting our Esprima Harmony
acorn_loose = require 'acorn/acorn_loose'  # for if Esprima dies. Note it can't do ES6.

Language = require './language'
traversal = require '../traversal'

module.exports = class JavaScript extends Language
  name: 'JavaScript'
  id: 'javascript'

  # Return true if we can very quickly identify a syntax error.
  obviouslyCannotTranspile: (rawCode) ->
    try
      # Inspired by ACE: https://github.com/ajaxorg/ace/blob/master/lib/ace/mode/javascript_worker.js
      eval "'use strict;'\nthrow 0;" + rawCode  # evaluated code can only create variables in this function
    catch e
      return true unless e is 0
    false

  # Return true if there are significant (non-whitespace) differences in the ASTs for a and b.
  hasChangedASTs: (a, b) ->
    # We try first with Esprima, to be precise, then with acorn_loose if that doesn't work.
    options = {loc: false, range: false, comment: false, tolerant: true}
    [aAST, bAST] = [null, null]
    try aAST = esprima.parse a, options
    try bAST = esprima.parse b, options
    return true if (not aAST or not bAST) and (aAST or bAST)
    if aAST and bAST
      return true if (aAST.errors ? []).length isnt (bAST.errors ? []).length
      return not _.isEqual(aAST.body, bAST.body)
    # Esprima couldn't parse either ASTs, so let's fall back to acorn_loose
    options = {locations: false, tabSize: 4, ecmaVersion: 5}
    aAST = acorn_loose.parse_dammit a, options
    bAST = acorn_loose.parse_dammit b, options
    # acorn_loose annoyingly puts start/end in every node; we'll remove before comparing
    removeLocations = (node) -> node.start = node.end = null
    traversal.walkAST aAST, removeLocations
    traversal.walkAST bAST, removeLocations
    return not _.isEqual(aAST, bAST)

  # Return an array of problems detected during linting.
  lint: (rawCode, aether) ->
    lintProblems = []
    wrappedCode = @wrap rawCode, aether

    # Run it through JSHint first, because that doesn't rely on Esprima
    # See also how ACE does it: https://github.com/ajaxorg/ace/blob/master/lib/ace/mode/javascript_worker.js
    # TODO: make JSHint stop providing these globals somehow; the below doesn't work
    jshintOptions = browser: false, couch: false, devel: false, dojo: false, jquery: false, mootools: false, node: false, nonstandard: false, phantom: false, prototypejs: false, rhino: false, worker: false, wsh: false, yui: false
    jshintGlobals = _.zipObject jshintGlobals, (false for g in aether.allGlobals)  # JSHint expects {key: writable} globals
    # Doesn't work; can't find a way to skip warnings from JSHint programmatic options instead of in code comments.
    #for problemID, problem of @originalOptions.problems when problem.level is 'ignore' and /jshint/.test problemID
    #  console.log 'gotta ignore', problem, '-' + problemID.replace('jshint_', '')
    #  jshintOptions['-' + problemID.replace('jshint_', '')] = true
    try
      jshintSuccess = jshint(wrappedCode, jshintOptions, jshintGlobals)
    catch e
      console.warn "JSHint died with error", e  #, "on code\n", wrappedCode
    for error in jshint.errors
      lintProblems.push aether.createUserCodeProblem type: 'transpile', reporter: 'jshint', error: error, code: wrappedCode, codePrefix: aether.wrappedCodePrefix

    lintProblems

  # Return a beautified representation of the code (cleaning up indentation, etc.)
  beautify: (rawCode) ->
    try
      ast = esprima.parse rawCode, {range: true, tokens: true, comment: true, tolerant: true}
      ast = escodegen.attachComments ast, ast.comments, ast.tokens
    catch e
      console.log 'got error beautifying', e
      ast = acorn_loose.parse_dammit rawCode, {tabSize: 4, ecmaVersion: 5}
    beautified = escodegen.generate ast, {comment: true, parse: esprima.parse}
    beautified

  # Wrap the user code in a function. Store @wrappedCodePrefix and @wrappedCodeSuffix.
  wrap: (rawCode, aether) ->
    @wrappedCodePrefix ?="""
    function #{aether.options.functionName or 'foo'}(#{aether.options.functionParameters.join(', ')}) {
    \"use strict\";
    """
    # Should add \n after? (Not `"use strict";this.moveXY(30, 26);` on one line.)
    # TODO: Try it and make sure our line counts are fine.
    @wrappedCodeSuffix ?= "\n}"
    @wrappedCodePrefix + rawCode + @wrappedCodeSuffix

  # Hacky McHack step for things we can't easily change via AST transforms (which preserve statement ranges).
  # TODO: Should probably refactor and get rid of this soon.
  hackCommonMistakes: (code) ->
    # Stop this.\n from failing on the next weird line
    code = code.replace /this\.\s*?\n/g, "this.IncompleteThisReference;"
    # If we wanted to do it just when it would hit the ending } but allow multiline this refs:
    #code = code.replace /this.(\s+})$/, "this.IncompleteThisReference;$1"
    code

  # Using a third-party parser, produce an AST in the standardized Mozilla format.
  parse: (code) ->
    ast = esprima.parse code, {range: true, loc: true}

  # Optional: if parseDammit() is implemented, then if parse() throws an error, we'll try again using parseDammit().
  # Useful for parsing incomplete code as it is being written without giving up.
  # This should never throw an error and should always return some sort of AST, even if incomplete or empty.
  parseDammit: (code) ->
    ast = acorn_loose.parse_dammit code, {locations: true, tabSize: 4, ecmaVersion: 5}

    # Esprima uses "range", but acorn_loose only has "locations"
    lines = code.replace(/\n/g, '\n空').split '空'  # split while preserving newlines
    posToOffset = (pos) ->
      _.reduce(lines.slice(0, pos.line - 1), ((sum, line) -> sum + line.length), 0) + pos.column
      # lines are 1-indexed, and I think columns are 0-indexed, but should verify
    locToRange = (loc) ->
      [posToOffset(loc.start), posToOffset(loc.end)]
    fixNodeRange = (node) ->
      # Sometimes you can get an if-statement with "alternate": null
      node.range = locToRange node.loc if node and node.loc
    traversal.walkAST ast, fixNodeRange

    ast