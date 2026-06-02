package policy

import (
	"strings"

	"gopkg.in/yaml.v3"
)

// MarshalMulti renders one or more CNPs as a multi-document YAML stream, the form
// you paste into `oc apply -f -`.
func MarshalMulti(cnps []CNP) (string, error) {
	var b strings.Builder
	for i, c := range cnps {
		if i > 0 {
			b.WriteString("---\n")
		}
		out, err := yaml.Marshal(c)
		if err != nil {
			return "", err
		}
		b.Write(out)
	}
	return b.String(), nil
}
