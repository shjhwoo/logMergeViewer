package main

import (
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"
	"time"
)

var processName string
var processId int

func main() {

	args := os.Args

	log.Println("입력받은 인자: ", args)

	if len(args) > 1 {
		pName, pId, err := extractProcessNameAndId(args[1])
		if err != nil {
			return
		}

		processName = pName
		processId = pId
	}

	//var cnt int

	for {
		fmt.Printf("Hello, World! from %s %v\n", processName, time.Now().Add(time.Hour))
		time.Sleep(time.Duration(processId*5) * time.Second)
		// cnt++
		// if cnt >= 5 {
		// 	break
		// }
	}
}

func extractProcessNameAndId(path string) (string, int, error) {
	suffix := "/cmd"

	trimmed := strings.TrimSuffix(path, suffix)

	processName := strings.TrimPrefix(trimmed, "./")

	processId, err := strconv.Atoi(strings.ReplaceAll(processName, "process", ""))
	if err != nil {
		fmt.Println("Error converting process ID:", err)
		return "", 0, err
	}

	return processName, processId, nil
}
