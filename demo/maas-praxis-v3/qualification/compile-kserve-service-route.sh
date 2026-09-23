#!/usr/bin/env bash
set -euo pipefail
: "${1:?route JSON is required}"
: "${2:?service name is required}"
: "${3:?service port is required}"
: "${4:?service namespace is required}"
route_json=$1
service_name=$2
service_port=$3
service_namespace=$4
jq -e --arg name "$service_name" --arg namespace "$service_namespace" --argjson port "$service_port" '
  [ .spec.rules[]
    | . as $rule
    | [ $rule.backendRefs[]?
        | select((.group // "") == "" and (.kind // "Service") == "Service"
                 and .name == $name and (.namespace // $namespace) == $namespace
                 and (.port == $port)) ] as $refs
    | select(($refs | length) == 1)
    | select([ $rule.matches[]?.path?.value
              | select(type == "string" and startswith("/" + $namespace + "/")
                       and endswith("/v1/chat/completions")) ] | length > 0)
    | {
        backendRef: {group: ($refs[0].group // ""), kind: ($refs[0].kind // "Service"), name: $refs[0].name, namespace: ($refs[0].namespace // $namespace), port: $refs[0].port},
        matches: [ $rule.matches[]?.path?.value | select(type == "string") ],
        rewrites: [ $rule.filters[]?.urlRewrite?.path?.replacePrefixMatch | select(type == "string") ]
      }
  ] as $matches
  | if ($matches | length) != 1 then error("expected exactly one HTTPRoute rule for backend Service")
    elif (($matches[0].matches | length) == 0) then error("matched HTTPRoute rule has no path matches")
    elif (($matches[0].rewrites | length) != 1) then error("matched HTTPRoute rule must have exactly one URL rewrite")
    else ($matches[0].matches
          | map(select(startswith("/" + $namespace + "/") and endswith("/v1/chat/completions"))
               | sub("/v1/chat/completions$"; "")) | unique) as $prefixes
      | if ($prefixes | length) != 1 then error("expected one chat-completions client prefix")
        else $matches[0] + {clientPrefix: $prefixes[0], backendRewrite: $matches[0].rewrites[0]}
        end
    end
' "$route_json"
