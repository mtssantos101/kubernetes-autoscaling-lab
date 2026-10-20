FROM eclipse-temurin:25-jdk-alpine AS base
WORKDIR /app

COPY pom.xml mvnw ./
COPY .mvn .mvn
RUN chmod +x mvnw && ./mvnw dependency:go-offline -B -q

FROM base AS development
EXPOSE 8080

CMD ["./mvnw", "spring-boot:run"]

FROM base AS build
COPY src/ src/
RUN ./mvnw clean package -DskipTests -B -q

FROM eclipse-temurin:25-jre-alpine AS production
WORKDIR /app

RUN addgroup -S spring && adduser -S spring -G spring
COPY --chown=spring:spring --from=build /app/target/*.jar /app/app.jar

USER spring:spring
EXPOSE 8080

ENTRYPOINT ["java", "-jar", "/app/app.jar"]
