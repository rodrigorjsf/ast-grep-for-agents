package main

import (
	"context"
	"errors"
	"fmt"
)

func process(input string) (string, error) {
	fmt.Println("debug:", input) // debug print left in
	result, err := doWork(input)
	if err != nil { // err-check boilerplate
		return "", err
	}
	return result, nil
}

func doWork(s string) (string, error) {
	if s == "" {
		return "", errors.New("empty")
	}
	return s, nil
}

func main() {
	out, _ := process("hello") // ignored error
	ctx := context.TODO()      // placeholder context left in
	_ = ctx
	fmt.Println(out)
}
