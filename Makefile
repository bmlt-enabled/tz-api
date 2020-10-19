lambda.zip:
	pip install --target ./lambda .
	cd lambda && zip -r9 ../lambda.zip .

zip: clean lambda.zip

deploy:
	cd terraform && terraform apply
clean:
	rm -rf lambda lambda.zip

.PHONY: zip clean deploy
